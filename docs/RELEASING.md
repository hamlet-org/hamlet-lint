# Releasing hamlet-lint

Operational reference for cutting a hamlet-lint release. The *why* of
the lockstep-with-hamlet, single-trunk packaging model lives in
`README.md` §2; this file is the *how*.

Two kinds of release event exist:

- **Hamlet release pass.** Triggered by every new `hamlet.X.Y.Z` on
  opam-repository. Publishes `hamlet-lint.X.Y.Z-<ocaml>` for every
  supported OCaml minor, from the current `main` commit.
- **OCaml release pass (backfill).** Triggered when a new OCaml minor
  starts being supported. Publishes `X.Y.Z-<new-ocaml>` for every past
  hamlet release, from the current `main` commit.

Both paths use the same release workflow; they differ only in which
axis you enumerate.

---

## 1. The release pieces at a glance

A single published package consists of:

- A **git tag** `v<hamlet>-<ocaml>` (e.g. `v0.1.0-5.4.1`), annotated,
  pushed to `origin`. The OCaml part is the full `major.minor.patch`:
  one build = one patch, the label names it exactly.
- A **GitHub Release** with the same name and a `git archive` tarball
  asset.
- An **opam-repository PR** adding one directory under
  `packages/hamlet-lint/`, with an `opam` file rendered from
  `release/hamlet-lint.opam.tmpl`. The rendered `ocaml` constraint is
  an exact pin `{= "<patch>"}`: `extract/compat.cppo.ml`'s `#error`
  guard accepts exactly that patch, so the build artifact is
  patch-specific and the package metadata says so.

One workflow run produces exactly one of each. Shipping for multiple
`(hamlet, ocaml)` pairs means triggering the workflow multiple times.
Use `./release/run.sh` (see §3) instead of typing them in by hand.

---

## 2. CHANGELOG.md

There is **one changelog** at the repo root, `CHANGELOG.md`. Entries
are chronological, keyed by *what changed in the walker*, not by
release events. Heading format:

```markdown
## YYYY-MM-DD: short title describing the change

Free-form body. [5.4 only] tag in the title if the change affects
only one OCaml target (typically compat-firewall work).
```

**No "version" heading.** The packaging label
`hamlet-lint.<hamlet>-<ocaml>` is not a line of walker development;
many packages can be built from the same `main` commit without any
entry in `CHANGELOG.md` (because the walker did not change). And many
entries can accumulate between releases.

### When to add an entry

- You changed the walker, analyzer, compat firewall, or wire schema
  in a way a downstream user would care about.
- You added / changed recognition for a combinator.
- You fixed a false positive or a false negative.
- You dropped / added an OCaml target (tag `[5.x only]` or an intro
  sentence explaining which target(s) are affected).

### When *not* to add an entry

- You ran a release pass for a new hamlet version and the walker was
  unchanged. The release event is a GitHub Release with its own
  notes; don't duplicate in `CHANGELOG.md`.
- You refactored without user-visible behaviour change.
- You ran a backfill for a new OCaml target whose compat work was
  already landed in an earlier entry.

### Release workflow and CHANGELOG

The release workflow does not grep `CHANGELOG.md`. There is no
"per-release heading" to validate because packages and entries are
decoupled (see §3 below). Changelog curation is a manual
responsibility of the maintainer running the release. Check it's up
to date before triggering.

---

## 3. The release dispatcher: `release/run.sh`

Both release passes below are driven by `./release/run.sh`. The script
reads `release/versions.sh` for the supported OCaml patches, then for
every `(hamlet, ocaml)` pair:

1. Checks `packages/hamlet-lint/hamlet-lint.<pair>/` on
   `ocaml/opam-repository`. Present = merged, skip.
2. Checks for an open PR titled `hamlet-lint <pair>` on the same repo.
   Present = in flight, skip.
3. Otherwise invokes `gh workflow run release.yml` with the pair.

The release workflow itself repeats check 1 in a `guard` job so that a
direct Run Workflow from the Actions UI is equally safe.

`release/versions.sh` defines `OCAML_PATCHES`, the supported OCaml
patches, grouped by `major.minor` line for readability. Each entry is
a full opam version string, including prereleases like `5.5.0~alpha1`.
The patch is simultaneously the label that appears in the package
version string and the exact pin in the generated opam file (no
derived bounds). Mirroring is still required with
`.github/workflows/ci.yml` (matrix row), the `#error` guard in
`extract/compat.cppo.ml`, and the `(ocaml ...)` bound in
`dune-project`, but all of them now agree on the exact same patch.

There is no `HAMLET_VERSION` in `versions.sh`. A release is always
for an explicit hamlet version that has already been published on
opam-repository; pass it on the command line.

Invocations:

```sh
./release/run.sh 0.1.0           # one hamlet version, every patch
./release/run.sh 0.1.0 0.2.0     # backfill over several hamlet versions
./release/run.sh --all           # backfill every hamlet ever published
```

## 4. Cutting a hamlet release pass (most common)

Hamlet has just published `X.Y.Z` to opam-repository. Do this.

1. **Pull `main` and verify green locally.** `make all` with your
   dev switch pinning `hamlet.X.Y.Z`. If the walker is broken against
   the new hamlet (rename, new combinator, shape change), fix it on
   `main` first and land the fix through normal PR flow. Only a green
   `main` is releasable.

2. **Update `CHANGELOG.md` if the walker changed.** If the release
   pass required a walker / analyzer / compat fix, you already
   landed an entry for it on `main` when you fixed the code. If no
   walker changes were needed, add nothing: the release event is
   recorded by GitHub Releases, not by `CHANGELOG.md` (see §2).

3. **Bump `HAMLET_VERSION` in `.github/workflows/ci.yml`** to `X.Y.Z`
   so CI keeps testing `main` against the current hamlet.

4. **Run `./release/run.sh X.Y.Z`.** The script crosses the new hamlet
   version with every patch in `OCAML_PATCHES`, skips what is already
   merged, and dispatches one workflow run per missing pair.

5. **Verify the opam-repository PRs are green** and merge once CI
   passes upstream.

## 5. Cutting an OCaml release pass (backfill)

Some future OCaml patch `<NEW>` has become supported and you want
every past hamlet release to be installable on it. Today only
`5.4.1` is in `OCAML_PATCHES`; this section describes the shape of
the procedure when a second entry gets added, not a commitment to
any specific future version.

1. **Pull `main` and verify green** against `<NEW>` locally. Fix
   any `compiler-libs` drift in `extract/compat.cppo.ml` on `main`,
   widening the `#error` guard to also accept `<NEW>` via a new
   `#if OCAML_VERSION = (...)` branch. Loosen the `(ocaml …)`
   bound in `dune-project` so both patches pass. Add a `<NEW>` row
   to the CI matrix in `.github/workflows/ci.yml`.

2. **Extend `release/versions.sh`** in the same commit: append
   `<NEW>` to its `major.minor` row in `OCAML_PATCHES` (or add a new
   row if it's a new minor line). No bounds to edit: the patch is
   the pin.

3. **Add a single `CHANGELOG.md` entry** for the new target,
   titled `## YYYY-MM-DD: OCaml <NEW> target added [<NEW> only]`,
   summarising the compat-firewall work. One entry describes the
   walker work once, regardless of how many past hamlet releases
   you then backfill.

4. **Run `./release/run.sh --all`.** Only after the new patch has
   been added to `OCAML_PATCHES` in step 2 — the `--all` form does
   not enlarge the OCaml axis, it just enumerates every hamlet ever
   published on `ocaml/opam-repository` (by listing
   `packages/hamlet-lint/` and stripping the `-<ocaml>` suffix) and
   crosses each with the current `OCAML_PATCHES`. Without step 2 the
   new patch is not in the support window and `--all` will dispatch
   nothing new (every existing pair is already merged and skipped).
   Equivalent to passing the full list by hand:

   ```sh
   ./release/run.sh 0.1.0 0.2.0 0.3.0   # explicit form
   ./release/run.sh --all               # auto-enumerated form
   ```

   The script crosses each hamlet with every patch in
   `OCAML_PATCHES` (now including `<NEW>`), skips pairs that
   already exist on opam-repository, and dispatches one workflow
   run per missing pair. On a fresh backfill this is `N × 1` new
   runs (N past hamlets × the new OCaml patch); pairs for the old
   patches are all skipped.

5. **Monitor the opam-repository PRs.** Each one is independent.

### Why backfill is not a no-op rename

Every package built for a new OCaml minor exercises the walker's
`compiler-libs` code against that minor's `Typedtree` / `Cmt_format`
shape. A backfill that passes CI is a real test that the walker's
compat firewall still works against that hamlet's fixtures; it is
not busywork.

---

## 5. Anatomy of the release workflow

`.github/workflows/release.yml` is triggered via `workflow_dispatch`
with two inputs: `hamlet_version` and `ocaml_target`. High-level
steps:

1. **Checkout `main`.** The workflow never releases from other
   branches, because trunk is the only source of truth (see the versioning
   model in `README.md` §2).
2. **Set up OCaml** at `ocaml_target`.
3. **Install `hamlet.<hamlet_version>`** from opam-repository. This
   is the steady-state install path; the bootstrap `git` mode in
   `ci.yml` is not used at release time. If the version does not
   exist on opam-repository yet, the workflow fails fast: you
   cannot release hamlet-lint for a hamlet that is not yet on opam.
4. **Build + test.** `dune build && dune runtest`. Any failure
   aborts the release: a package that cannot build for its own
   declared `(hamlet, ocaml)` pair must not ship.
5. **Render opam file** from `release/hamlet-lint.opam.tmpl` by
   substituting:
   - `%%VERSION%%` → `<hamlet_version>-<ocaml_target>`
   - `%%HAMLET_VERSION%%` → `<hamlet_version>`
   - `%%OCAML_TARGET%%` → `<ocaml_target>` (the exact patch)
   - `%%TARBALL_URL%%` + `%%CHECKSUM_SHA256%%` after uploading the
     archive to the GitHub Release.
6. **Create git tag** `v<hamlet_version>-<ocaml_target>`, push it.
7. **Create GitHub Release** with the tag, upload the `git archive`
   tarball as an asset.
8. **Open opam-repository PR** via `gh`, forking if needed, creating
   `packages/hamlet-lint/hamlet-lint.<hamlet>-<ocaml>/opam`,
   committing, pushing, opening the PR.

### 5.1 Option: pre-preprocess the cppo file per target

Because each published package is already bound to exactly one OCaml
minor (the `-<ocaml>` suffix in the package name), the release workflow
could run
`cppo -V OCAML:<ocaml_target>.x extract/compat.cppo.ml -o extract/compat.ml`,
drop the `(rule …)` stanza from `extract/dune`, remove `cppo` from the
opam template, and ship a plain `compat.ml` already specialised for
its target. End users would then install without `cppo` as a build dep.

Pros: one fewer build dep on the user side; no cppo version skew; the
shipped `compat.ml` is literally the code that runs. Cons: the tarball
stops being a `git archive` (must be built then packed, reproducibility
becomes a procedure rather than a command); the shipped sources diverge
from `main`, making bug reports harder to trace back; the release
workflow grows two extra mutation steps. Today it's not worth the
complication. Revisit if `cppo` ever becomes a supply-chain concern
downstream.

---

## 6. Why not `dune-release`

`dune-release` is the standard opam release tool, but three features
of our scheme fight its defaults:

1. Our version strings contain a `-` suffix (`0.1.0-5.4`). The
   `dune-release` parser does not handle this shape as we want.
2. We publish many packages from one commit (lockstep backfill).
   `dune-release` assumes one tag = one shipped package.
3. Our changelog is decoupled from release events (see §2); the
   release workflow neither greps it nor validates it.

The manual `gh`-based flow in `release.yml` is ~40 lines of shell
and sidesteps all three.

---

## 7. Testing across OCaml targets

CI's `build` job in `ci.yml` matrix-tests every supported OCaml
minor on every push. Each matrix row spins up a fresh switch, pins
hamlet via `HAMLET_SOURCE`, and runs the full suite, the same code
path that will later be exercised at release time. A PR that breaks
a minor fails CI before it lands on `main`, which means `main` is
always releasable for every supported minor.

The release workflow re-runs the same build + test at release time
as a second layer of verification. Belt and braces.

---

## 8. Release checklist

Before triggering the workflow:

- [ ] `main` is green in CI for the target OCaml minor.
- [ ] `hamlet.<hamlet_version>` is merged on opam-repository and
      installable via `opam install hamlet.<hamlet_version>`.
- [ ] `CHANGELOG.md` is up to date if the walker changed since the
      last release pass.
- [ ] `HAMLET_VERSION` in `ci.yml` points at the new hamlet (for
      hamlet release pass only).
- [ ] You have `gh auth` access to `hamlet-org/hamlet-lint` and
      `ocaml/opam-repository`.

Then: **Actions → release → Run workflow → fill inputs → go**.

---

## 9. Related files

- `.github/workflows/ci.yml`: CI matrix, bootstrap hamlet install.
- `.github/workflows/release.yml`: the parameterised release job.
- `release/hamlet-lint.opam.tmpl`: opam template with
  `%%…%%` placeholders.
- `hamlet-lint.opam`: dev-time opam file generated by dune; not
  shipped, never edited by hand.
- `CHANGELOG.md`: single chronological walker/analyzer history.
  Decoupled from release events.
- `extract/compat.cppo.ml`: compiler-libs firewall, cppo-preprocessed;
  edit here (and widen the `#error` guard) when a new OCaml minor
  breaks the walker.
- `README.md` §2: the versioning model rationale.
