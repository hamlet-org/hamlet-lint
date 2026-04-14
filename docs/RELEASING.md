# Releasing hamlet-lint

Operational reference for cutting a hamlet-lint release. The *why* of
per-compiler versioning lives in `README.md` §9; this file is the
*how*: checklists, file formats, workflow mechanics, and the
background you need about multi-package opam monorepos to understand
why things are arranged the way they are.

> If you just want to ship a patch on OCaml 5.4, jump to §3.

---

## 1. The release pieces at a glance

A hamlet-lint release consists of:

- A **git tag** `hamlet-lint-<feature>-<ocaml_target>` (e.g.
  `hamlet-lint-0.1.0-5.4`), annotated, pushed to `origin`.
- A **GitHub Release** with the same name and a `git archive` tarball.
- An **opam-repository PR** adding one directory under
  `packages/hamlet-lint/`, with an `opam` file rendered from
  `release/hamlet-lint.opam.tmpl`.

One workflow run produces exactly one of each. Shipping the same feature
version for two OCaml minors means triggering the workflow twice.

Trigger: **Actions → hamlet-lint → Run workflow** on
`.github/workflows/lint.yml`, with `mode=release`, `feature_version=X.Y.Z`,
`ocaml_target=5.4`.

---

## 2. CHANGES-lint-\<target\>.md

There is no single `CHANGES-lint.md`. There is one file **per compiler
target** — today, `CHANGES-lint-5.4.md`. When OCaml 5.5 support is
added, a sibling `CHANGES-lint-5.5.md` will be created alongside it.
The two evolve independently.

### 2.1 Format

```markdown
# hamlet-lint changelog — OCaml <target> target

Preamble. Explains what the suffix means for this target.

## v<feature_version> (<YYYY-MM-DD>)

Release notes for this feature version, as markdown. The release
workflow copies everything from this heading up to (but not including)
the next `## v` heading and uses it as the body of the GitHub Release.

## v<older_feature_version> (<older_date>)

...

```

Headings must match the regex `^## v<feature_version>( |$)`. If the
workflow is triggered with a `feature_version` that has no matching
heading in the changelog for that target, it fails at the validation
step before doing anything destructive.

### 2.2 Why per-target files

See `README.md` §9.1 for the rationale. In short: one compiler target
is one product; each target has its own release history.

### 2.3 Cross-target synchronous releases

To ship an analyzer-only bugfix on both 5.4 and 5.5, add the same
`## v<feature>` entry to both `CHANGES-lint-5.4.md` and
`CHANGES-lint-5.5.md` (identical content), then trigger the workflow
twice — once per target. opam-repository ends up with
`hamlet-lint.0.1.2-5.4` and `hamlet-lint.0.1.2-5.5` side by side.

---

## 3. Cutting a release: the five-step checklist

Assume you're releasing a patch on OCaml 5.4 (the common case).

1. **Open a PR** that contains the code change and, in the same
   commit, an updated `CHANGES-lint-5.4.md` with a new
   `## v<new_feature_version> (<today>)` heading at the top.
2. **Wait for CI green.** The dogfood job runs on every PR and must
   pass before merging.
3. **Merge to main.** Standard merge button, no extra ceremony.
4. **Trigger the release workflow.** GitHub → Actions → hamlet-lint →
   Run workflow, pick `main`, `mode=release`,
   `feature_version=<new_feature_version>`, `ocaml_target=5.4`. Submit.
5. **Check the opam-repository PR.** The workflow opens it
   automatically from `hamlet-org/opam-repository` against
   `ocaml/opam-repository`. Review the rendered `.opam` file there,
   and merge once upstream CI is happy.

---

## 4. Releasing a new OCaml target for the first time

Supporting a new OCaml minor (say 5.5) is a larger operation because
it involves code, not just a changelog bump. The full procedure:

1. **Make the compat shim work.** Add `#if OCAML_VERSION >= (5, 5, 0)`
   branches inside `extract/compat.ml` covering every
   `compiler-libs` call that drifted. If this is the first time
   `compat.ml` needs preprocessing, add the `(preprocess (action (run
   cppo -V OCAML:%{ocaml_version} %{input-file})))` clause to
   `extract/dune`.
2. **Create `CHANGES-lint-5.5.md`.** Seed it with an initial
   `## v<initial_version>` entry. Feature parity with the current
   5.4 line is a reasonable starting point — the entry can just
   say "Initial 5.5 target; feature parity with 0.1.<N>-5.4".
3. **Add `5.5` to the dogfood matrix** (`.github/workflows/lint.yml`,
   `dogfood.strategy.matrix.ocaml-compiler`). From now on every push
   runs the linter on both switches.
4. **Add `5.5` to the `ocaml_target` workflow_dispatch enum** (same
   file, `release.inputs.ocaml_target.options`). Without this entry
   the workflow cannot be triggered for the new target.
5. **Merge the PR**, wait for CI green on both matrix cells.
6. **Trigger the release workflow** with `mode=release`,
   `feature_version=<initial_version>`, `ocaml_target=5.5`.

---

## 5. Dropping an OCaml target

Symmetric to adding one.

1. **Remove the `#if OCAML_VERSION < (X, Y, 0)` branches** for the
   dropped minor from `compat.ml`. If no shims remain, remove the
   `cppo` preprocess stanza from `extract/dune`.
2. **Remove the target from both the matrix and the enum** in
   `lint.yml`.
3. **Optionally archive `CHANGES-lint-<dropped>.md`** — move it to
   `docs/archive/` or delete it. The already-published versions
   in opam-repository are untouched; they remain installable forever
   unless explicitly yanked (which is a separate, rare operation).

Users on a dropped target continue to receive the last published
version for that target via `opam install hamlet-lint`. There is no
hard cutoff.

---

## 6. What the release workflow actually does

Annotated step-by-step of the `release` job in `.github/workflows/lint.yml`:

1. **Checkout with full history** (`fetch-depth: 0`) so `git archive`
   of the newly-created tag works.
2. **Install the target OCaml** (via `ocaml/setup-ocaml@v3`, pinned to
   `inputs.ocaml_target`). This guarantees the build we validate
   matches the constraint in the rendered opam file.
3. **Build and test** (`make build`, `make runtest`, `make lint`).
   Final sanity check on the release commit.
4. **Compose and validate version.** Extracts the feature version
   from the workflow input, checks it against the corresponding
   `CHANGES-lint-<target>.md`, derives the full version string
   (`<feature>-<target>`), derives the ocaml min/max range for the
   opam file, and exports all of these as step outputs.
5. **Ensure tag doesn't already exist** on origin. Refuses to
   re-release the same `(feature, target)` pair.
6. **Create and push the annotated tag** `hamlet-lint-<full>`.
7. **Create source tarball** with `git archive --prefix=...` from the
   freshly-pushed tag. Compute sha256.
8. **Extract release notes.** `awk` pulls the section from the
   changelog starting at the matching heading.
9. **Create GitHub Release** via `gh release create`, attach the
   tarball, capture the asset URL (needed for the opam file's
   `url.src` field).
10. **Render the opam file.** `sed` substitutes all `%%PLACEHOLDERS%%`
    in `release/hamlet-lint.opam.tmpl` with the real values.
11. **`opam lint` the rendered file.** Catches template-substitution
    typos before they become a rejected opam-repository PR.
12. **Submit to opam-repository.** Clones `hamlet-org/opam-repository`
    into a temp dir, creates a branch named `hamlet-lint-<full>`,
    drops the rendered `opam` file at
    `packages/hamlet-lint/hamlet-lint.<full>/opam`, commits, pushes
    the branch, and opens a PR against `ocaml/opam-repository` with
    `gh pr create --repo ocaml/opam-repository --head
    hamlet-org:<branch> --base master`.

Each step is annotated in the YAML; if the two drift, the YAML is the
source of truth.

---

## 7. Why not `dune-release`

`release.yml` uses `dune-release` for `hamlet` + `ppx_hamlet`. For
`hamlet-lint` it does not, because the merlin-style `-<target>` suffix
scheme fights `dune-release`'s defaults on three points:

1. The repo-root `hamlet-lint.opam` is pinned to the dev's current
   minor; if `dune-release` published it, the shipped version would
   lose its `-5.4` suffix and `ocaml_target` with it.
2. Our version strings contain a `-` suffix; `dune-release`'s parser
   handling of that as a prerelease is undocumented.
3. Our changelog is `CHANGES-lint-<target>.md`, not `CHANGES.md`.
   Overriding it via `--change-log` plus `--pkg-version`, `--tag`,
   `--opam` means fighting the tool on every flag.

Merlin works around this with a shell-script wrapper and one branch per
OCaml target. At our scale branches-per-target is more overhead than
cppo shims in `compat.ml`. The manual `gh` flow in `lint.yml` is ~40
lines of linear bash built from standard commands, and revisiting this
decision later is cheap if the manual approach ever hits friction.

---

## 8. How the two release pipelines interact

`release.yml` releases `hamlet` + `ppx_hamlet` together via
`dune-release`; `lint.yml` releases `hamlet-lint` independently. They
cannot collide:

1. Tag namespaces are disjoint (`vX.Y.Z` vs `hamlet-lint-X.Y.Z-O.P`).
2. `release.yml` passes explicit `--pkg-name hamlet` / `--pkg-name
   ppx_hamlet` so `dune-release` never discovers `hamlet-lint.opam`.
3. Both workflows are `workflow_dispatch`-only; neither runs on push.

`dune-project` is the one piece of shared dev metadata: it declares all
three `(package …)` stanzas and auto-generates all three dev-time
`.opam` files. If `hamlet-lint`'s dep constraints ever drift from the
others, the escape hatch is `(generate_opam_files false)` scoped to the
drifting package.

---

## 9. Testing across OCaml targets

Three test layers, all version-neutral by construction:

- **Rule tests** (`test/test_rule.ml`) build schema records in
  memory and drive `Rule.check_*` directly — pure OCaml, no
  `compiler-libs`, version-agnostic.
- **E2E fixtures** (`test/cases/<name>/`) are source `.ml` files
  in a `(library)` stanza. Dune compiles them with the active switch;
  `test_e2e.ml` shells out to `hamlet-lint-extract <cmt> | hamlet-lint`
  and asserts on the output. The same sources compile under any
  switch the extractor supports.
- **Dogfood** (`make lint`) runs the linter on hamlet's own
  `_build/lib` + `_build/ppx`.

Multi-version coverage comes from
`dogfood.strategy.matrix.ocaml-compiler` in
`.github/workflows/lint.yml`. Each matrix row spins up a fresh switch,
builds the extractor against that `compiler-libs`, and re-runs fixtures
and dogfood. Zero per-version fixtures, zero speculative `#if` branches
for unreleased compilers.

Gap: we do not currently snapshot the ND-JSON between the two binaries
byte-for-byte across OCaml versions. This would catch drift where the
extractor's output differs on the wire but the analyzer's semantic
assertions coincidentally still pass. Worth adding when a second OCaml
target lands; with one target there is nothing to diff against.

---

## 10. What to read next

- `README.md` §9 — the rationale for per-compiler versioning
- `README.md` §8 — the ND-JSON contract between the two binaries
- `.github/workflows/lint.yml` — the workflow itself, with inline
  comments that mirror §6 of this file
- `release/hamlet-lint.opam.tmpl` — the release-time template, with
  a placeholder reference in its header comment
