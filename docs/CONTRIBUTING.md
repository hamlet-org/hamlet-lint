# Contributing to hamlet-lint

Internal reference for common extension tasks. For architecture and
the wire contract see `ARCHITECTURE.md`; for the rule see `RULE.md`;
for the release model see `RELEASING.md`.

---

## 0. Setup

After cloning, enable the repo's git hooks (one-time, per clone):

```bash
make hooks
# or, equivalently:
git config core.hooksPath .githooks
```

This installs a pre-commit hook that runs `dune fmt --auto-promote`
on staged `.ml` / `.mli` / `dune` / `dune-project` files and re-stages
the formatted versions, so CI's `@fmt` check never trips you up.

`make help` lists every other dev target (build, test, fmt, doc,
opam, promote, plus the fixture-scoped `run` / `ndjson` / `debug`
helpers).

---

## 1. How to add a new test case

Two layers:

- **Rule unit tests** in `test/test_rule.ml` exercise `Rule.check` /
  `Rule.analyze` against hand-built `Schema.candidate` records — no
  compiler-libs and no fixtures. The right place for set-difference
  semantics, kind preservation, header skipping. Use the local
  `mk_candidate ?kind ?combinator ~declared ~upstream ()` helper.
- **End-to-end fixtures** under `test/cases/*.ml` (one module per
  combinator family or shape group: `widening_cases`, `edge_cases`,
  `layer_cases`, `cross_cu_cases`). All fixtures share one dune
  library `hamlet_lint_fixtures`; add new files to the `(modules ...)`
  list in `test/cases/dune` and to `.ocamlformat-ignore` if you want
  source-line numbers stable.
- The driver `test/test_e2e.ml` is table-driven: add a row to `cases`
  with the fixture's capitalised module name, expected exit code, and
  the source-line numbers that must show up flagged.

Run `make test` (or `opam exec -- dune runtest --force`).

---

## 2. How to add support for a new combinator

If Hamlet grows an eighth handler-driven combinator, hook it in:

1. Add an entry to either `single_arg_paths` (single-arg handler,
   annotation on first param) or `curried_paths` (curried handler,
   `svc -> r_in -> dispatch`, annotation on second param) in
   `extract/classify.ml`. Tag it with `` `Catch `` (slot 1, errors)
   or `` `Provide `` (slot 2, services).
2. Add the bare-name version to `single_arg_lasts` /
   `curried_lasts` so the fallback (used for `let open` and
   `let module` aliases) recognises the combinator.
3. If the upstream is at a non-standard argument position, extend
   `extract_upstream` in `extract/walker.ml`. The default picks the
   first positional (no-label) argument.
4. If the handler uses a label other than `~f` / `~h`, extend
   `extract_handler`.
5. Add fixtures (one GOOD, one BAD) to `test/cases/layer_cases.ml`
   (or wherever fits) and an entry in `test/test_e2e.ml::cases`.
6. Update the combinator table in `docs/RULE.md` §2.

The walker emits the actual callee short-name in the candidate's
`combinator` field, so the report names it correctly without further
work.

---

## 3. How to add a new handler shape

If a Hamlet idiom uses a handler form not covered by the 5 recognised
shapes (param-pat, function-cases, scrutinee, named ident, single
apply), extend `extract/handler.ml`:

1. Add a new branch to `universe_tags` (or a helper called from it).
2. Document the shape in `docs/RULE.md` §3.3.
3. Add a fixture to `test/cases/edge_cases.ml`.

The walker passes `~peel:0` for single-arg combinators and `~peel:1`
for curried Layer.provide_to_*; add `~peel:n` if a new combinator
needs more layers stripped.

---

## 4. How to add a new OCaml target

When a new OCaml patch `<NEW>` starts being supported (today only
`5.4.1` is in `OCAML_PATCHES`):

1. Widen the top-of-file `#error` guard in `extract/compat.cppo.ml`
   to admit `<NEW>`.
2. Wrap any `compiler-libs`-facing body that drifted in
   `#if OCAML_VERSION >= (...) … #endif`. `compat.cppo.ml` is the
   only file in the repo that cppo touches. Everything else is plain
   OCaml.
3. Loosen the `(ocaml …)` bound in `dune-project` to cover `<NEW>`.
4. Add a row to the CI matrix in `.github/workflows/ci.yml` so both
   patches are exercised on every push.
5. Append `<NEW>` to `OCAML_PATCHES` in `release/versions.sh`.
6. Follow `docs/RELEASING.md` §5 for the backfill release pass.
