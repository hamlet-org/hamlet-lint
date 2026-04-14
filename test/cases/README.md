# Fixtures layout

Each subdirectory under `test/cases/` is a self-contained
hamlet-lint test fixture. A fixture is **input** to the linter, not
test code: it exists so the pipeline under test (`hamlet-lint-extract
| hamlet-lint`) has something concrete to read.

## What a fixture directory contains

- A small `.ml` file (two for cross-module cases) exhibiting the
  pattern under test.
- A `dune` file with a single `(library …)` stanza so dune produces a
  `.cmt` under `_build/default/test/cases/<name>/<name>.cmt`.

`test/test_e2e.ml` uses each fixture's `.cmt` as static data: for
every case it runs `hamlet-lint-extract --canonical <cmt> | hamlet-lint`
and asserts on the output.

## Why one directory per fixture

The alternative is a single `(library … (wrapped false))` covering all
fixtures as submodules. We keep per-directory for **isolation**: a type
error in one fixture does not block the others, which matters while
developing a new case. The boilerplate cost is ~3 lines of `dune` per
directory. Nothing in the walker, analyzer, or `test_e2e.ml` depends on
this layout, so the consolidated variant remains a valid future
refactor.

## Adding a new fixture

1. Create `test/cases/<name>/<name>.ml` with the smallest Hamlet
   program that exhibits the pattern under test. Prefer closed row
   types (explicit annotations) to avoid weak polymorphism warnings.
2. Create `test/cases/<name>/dune` with:
   ```
   (library
    (name hamlet_lint_fixture_<name>)
    (libraries hamlet))
   ```
   Add `(preprocess (pps ppx_hamlet))` if the fixture uses PPX
   extensions.
3. Add a row to the `e2e_cases` table in `test/test_e2e.ml` specifying
   the fixture name, how to resolve its subject (single `.cmt` or whole
   directory), the expected exit code, and the substrings that must
   (or must not) appear in the output.

Run the suite with `dune runtest`. When a deliberate change shifts
expected output, regenerate snapshots with `dune promote`.

## Running the linter on a single fixture

For interactive exploration (iterating on the walker, debugging a
new rule, inspecting what the extractor emits), use the targets in
the top-level `Makefile`:

```bash
make list                          # show available fixtures
make run     FIXTURE=wrapper_stale # pipe extractor | analyzer, pretty report
make ndjson  FIXTURE=wrapper_stale # raw canonical ND-JSON
make debug   FIXTURE=wrapper_stale # same as run but with HAMLET_LINT_DEBUG=1
make test                          # run the whole test suite
make help                          # show all targets
```

Each target ensures `make build` has run first, then invokes the
binaries directly from `_build/default/{extract,analyzer}/main.exe`
with the fixture's `.cmt` as input. No need to remember long paths or
chain commands by hand.
