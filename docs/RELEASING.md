# Releasing hamlet-lint

How to cut a release. *Why* of the lockstep-with-hamlet packaging
model is in `README.md` §2.

Two release events:

- **Hamlet release pass**: triggered by every new `hamlet.X.Y.Z` on
  opam-repository. Publishes `hamlet-lint.X.Y.Z~<ocaml>` for every
  supported OCaml patch, from current `main`.
- **OCaml release pass (backfill)**: triggered when a new OCaml patch
  starts being supported. Publishes `X.Y.Z~<new-ocaml>` for every
  past hamlet release, from current `main`.

Both use the same workflow; they differ only in which axis is
enumerated.

## 1. Per-pair release artifacts

A pass publishes N pairs in one workflow run. Per pair:

- **Git tag** `v<hamlet>-<ocaml>` (e.g. `v0.1.0-5.4.1`), annotated,
  pushed. Hyphen because git refs forbid `~`.
- **GitHub Release** with the same name + `git archive` tarball.

For the whole pass: **one** opam-repository PR adding every package
directory at once, named `hamlet-lint.<hamlet>~<ocaml>` (e.g.
`hamlet-lint.0.1.0~5.4.1`), each with an `opam` file rendered from
`release/hamlet-lint.opam.tmpl`. PR title:
`[new release] hamlet-lint (<pair>)` for one, or
`(<N> packages)` for several.

The rendered `ocaml` constraint is `{= "<patch>"}` (exact pin),
matching the patch in the package suffix one-to-one. The
`extract/compat.cppo.ml` `#error` guard accepts a minor-range
starting at the first supported patch (currently
`>= 5.4.1 < 5.5.0`); the per-package opam pin narrows to one patch
at install time.

Use `./release/run.sh`; do not paste JSON into the Actions UI by hand.

## 2. CHANGELOG.md

One chronological log at the repo root, keyed by *what changed in the
walker*, not by release events:

```markdown
## YYYY-MM-DD: short title

Free-form body. [5.4 only] tag if the change affects only one OCaml target.
```

**No "version" headings.** A release event is a GitHub Release; many
packages can be built from the same commit without any changelog
entry.

**Add an entry** for: walker / analyzer / compat / wire schema changes
visible to users; new combinator recognition; fixed false positives or
negatives; OCaml target changes (tag `[5.x only]`).

**Skip** for: release passes when the walker was unchanged; pure
refactoring; backfills whose compat work was already logged.

The release workflow does NOT grep `CHANGELOG.md`. Curation is
manual.

## 3. The dispatcher: `release/run.sh`

Reads `OCAML_PATCHES` from `release/versions.sh`. For every
`(hamlet, ocaml)` pair:

1. Skips if `packages/hamlet-lint/hamlet-lint.<hamlet>~<ocaml>/`
   already exists on `ocaml/opam-repository`.
2. Skips if any open opam-repository PR touching that package path
   already carries the pair (bundled PRs may carry several).
3. Bundles surviving pairs into one JSON array, dispatches **one**
   `gh workflow run release.yml`.

The release workflow's `plan` job repeats check 1 so a Run-Workflow
from the UI is equally safe.

`OCAML_PATCHES` in `release/versions.sh` is the supported-patches
list (full opam version strings, including prereleases). It mirrors:
the minor-range `#error` guard in `extract/compat.cppo.ml`, the
narrower `(ocaml ...)` bound in `dune-project` (single patch
during dev), and the matrix in `.github/workflows/ci.yml`. The
mirroring is conventional, not enforced — you must keep them in
sync when adding/removing patches.

There is no `HAMLET_VERSION` in `versions.sh`: pass it on the CLI.

```sh
./release/run.sh 0.1.0           # one hamlet, every patch
./release/run.sh 0.1.0 0.2.0     # backfill several hamlets
./release/run.sh --all           # every hamlet ever published
```

## 4. Hamlet release pass (most common)

Hamlet just published `X.Y.Z`. Do this:

1. **Pull `main` and verify green** with your dev switch pinned to
   `hamlet.X.Y.Z`. If the walker breaks, fix on `main` via normal PR
   flow first.
2. **Update `CHANGELOG.md`** if the walker changed (you'd have done
   this when you fixed the code).
3. **Bump `HAMLET_VERSION` in `.github/workflows/ci.yml`** to
   `X.Y.Z` so CI keeps testing `main` against the current hamlet.
4. **Run `./release/run.sh X.Y.Z`**.
5. **Verify the opam-repo PR is green** and merge.

## 5. OCaml release pass (backfill)

A new OCaml patch `<NEW>` is now supported, and you want every past
hamlet release installable on it.

1. **Pull `main`, verify green against `<NEW>`** locally. Fix any
   `compiler-libs` drift in `extract/compat.cppo.ml` (widen `#error`
   guard, add `#if OCAML_VERSION = (...)` branches as needed).
   Loosen `(ocaml ...)` in `dune-project`. Add `<NEW>` row to CI
   matrix.
2. **Append `<NEW>` to `OCAML_PATCHES`** in `release/versions.sh` in
   the same commit.
3. **Add one `CHANGELOG.md` entry** titled
   `## YYYY-MM-DD: OCaml <NEW> target added [<NEW> only]`.
4. **Run `./release/run.sh --all`**. The script crosses every past
   hamlet with `OCAML_PATCHES` (now including `<NEW>`), skips merged
   pairs, and dispatches **one** workflow run that bundles every
   surviving pair (the `build` job then matrix-fans-out internally).
   On a fresh backfill: one workflow run carrying `N × 1` pairs.
5. **Monitor the bundled opam-repo PR**. One PR carries every
   surviving pair (each pair = one independent package directory
   inside the PR).

A backfill that passes CI is a real test of the walker against that
patch's `Typedtree`/`Cmt_format`. Not busywork.

## 6. Workflow anatomy (`.github/workflows/release.yml`)

`workflow_dispatch` with one input: `pairs` (JSON array of
`{hamlet, ocaml}`). Three jobs:

**`plan`** (one job): re-filters `pairs` against
`ocaml/opam-repository`. Emits surviving list + count. Downstream
gated on `count != '0'`.

**`build`** (matrix over surviving pairs, `fail-fast: false`):

1. Checkout `main` (only source of truth).
2. Set up OCaml at the pair's patch.
3. Install `hamlet.<hamlet>` from opam-repository (fail fast if
   missing).
4. Build + test.
5. Create git archive, annotated tag `v<hamlet>-<ocaml>`, GitHub
   Release with the tarball.
6. Render opam file from `release/hamlet-lint.opam.tmpl`:
   - `%%VERSION%%` → `<hamlet>~<ocaml>`
   - `%%HAMLET_VERSION%%` → `<hamlet>`
   - `%%OCAML_TARGET%%` → `<ocaml>`
   - `%%TARBALL_URL%%` + `%%CHECKSUM_SHA256%%` after upload.
7. Upload rendered opam as artifact `opam-<hamlet>~<ocaml>`.

**`bundle-pr`** (one job, after `build`): downloads every artifact,
drops each into
`packages/hamlet-lint/hamlet-lint.<hamlet>~<ocaml>/opam` on a fresh
branch of `ocaml/opam-repository`, opens **one** PR. Branch name
`hamlet-lint-release-<run-id>`.

## 7. Why not `dune-release`

Three mismatches with our scheme:

1. Version strings contain `~` (`0.1.0~5.4.1`); `dune-release`'s
   parser doesn't handle it as we want.
2. We publish many packages from one commit (lockstep backfill);
   `dune-release` assumes one tag = one package.
3. Our changelog is decoupled from release events; the workflow
   doesn't grep it.

The manual `gh`-based flow in `release.yml` is ~40 lines of shell.

## 8. Release checklist

- [ ] `main` green in CI for the target OCaml patch.
- [ ] `hamlet.<hamlet>` merged on opam-repo and `opam install`-able.
- [ ] `CHANGELOG.md` up to date if walker changed.
- [ ] `HAMLET_VERSION` in `ci.yml` matches new hamlet (hamlet pass
      only).
- [ ] `gh auth` access to `hamlet-org/hamlet-lint` and
      `ocaml/opam-repository`.

Then run `./release/run.sh <hamlet-version>` (or `--all` for
backfill). The script computes the surviving pairs and dispatches
one workflow run with all of them. Fall back to **Actions → release
→ Run workflow** only when you need to force-dispatch a specific
pair list bypassing the in-flight-PR skip.

## 9. Related files

| File                                       | Purpose                                                     |
|--------------------------------------------|-------------------------------------------------------------|
| `.github/workflows/ci.yml`                 | CI matrix, bootstrap hamlet install                         |
| `.github/workflows/release.yml`            | The parameterised release job                               |
| `release/run.sh`                           | Dispatcher (skip-merged, bundle pairs, gh workflow run)     |
| `release/versions.sh`                      | `OCAML_PATCHES` list (one source of truth)                  |
| `release/hamlet-lint.opam.tmpl`            | opam template with `%%...%%` placeholders                   |
| `hamlet-lint.opam`                         | Dev-time opam (generated by dune; not shipped)              |
| `CHANGELOG.md`                             | Chronological walker history (decoupled from releases)      |
| `extract/compat.cppo.ml`                   | compiler-libs firewall (cppo-preprocessed)                  |
