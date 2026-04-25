# Contributing to hamlet-lint

Architecture in `ARCHITECTURE.md`. Rule in `RULE.md`. Releases in
`RELEASING.md`.

## 0. Setup

```bash
make hooks          # one-time per clone, installs pre-commit
```

The pre-commit hook runs `dune fmt --auto-promote` on staged OCaml /
dune files and re-stages the formatted versions, so CI's `@fmt` check
never trips.

`make help` lists every dev target.

## 1. Add a test case

- **Rule unit** (`test/test_rule.ml`): exercises `Rule.check` /
  `Rule.analyze` against hand-built `Schema.candidate` records. No
  compiler-libs, no fixtures. Use the local
  `mk_candidate ?kind ?combinator ~declared ~upstream ()`.
- **End-to-end fixture** (`test/cases/<name>.ml`): one module per
  combinator family or shape group. Add to `(modules ...)` in
  `test/cases/dune` and to `.ocamlformat-ignore` if you want stable
  source-line numbers.
- **Driver row** (`test/test_e2e.ml::cases`): capitalised module name,
  expected exit, source-line numbers that must show up flagged.

`make test`.

## 2. Add a combinator

Hooked in five places:

1. `extract/classify.ml`: add to `single_arg_paths` / `curried_paths`
   (canonical) AND `single_arg_lasts` / `curried_lasts` (bare-name
   fallback for `let open` / `let module`). Tag with `` `Catch ``
   (slot 1, errors) or `` `Provide `` (slot 2, services).
2. `extract/walker.ml`: extend `extract_upstream` if upstream isn't
   the first positional arg; extend `extract_handler` if the handler
   label is neither `~f` nor `~h`.
3. `extract/upstream.ml`: if the new combinator participates in
   chained inline residual, extend `residual_through` with its slot
   semantics (which slots it touches vs. passes through).
4. Fixtures (one GOOD, one BAD) in the appropriate `test/cases/*.ml`,
   plus an entry in `test/test_e2e.ml::cases`.
5. `docs/RULE.md` §2 combinator table.

The walker emits the actual callee short-name as `combinator` in the
candidate, so the report names it correctly without further work.

## 3. Add a handler shape

If a Hamlet idiom uses a handler form not covered by the 5 recognised
shapes (param-pat, function-cases, scrutinee, named ident,
single-apply):

1. Add a branch to `extract/handler.ml::universe_tags`.
2. Document in `docs/RULE.md` §3.3.
3. Fixture in `test/cases/edge_cases.ml`.

`~peel:n` strips `n` outer `Texp_function` layers (used for curried
`Layer.provide_to_*` handlers). Add a `~peel:` plumbing if a new
combinator needs more layers stripped.

## 4. Add an OCaml target

When patch `<NEW>` starts being supported (today only `5.4.1` in
`OCAML_PATCHES`):

1. Widen `#error` guard in `extract/compat.cppo.ml` to admit `<NEW>`.
2. Wrap any `compiler-libs`-facing body that drifted in
   `#if OCAML_VERSION >= (...) … #endif`. Only `compat.cppo.ml` uses
   cppo; everything else is plain OCaml.
3. Loosen `(ocaml ...)` in `dune-project`.
4. Add a CI matrix row in `.github/workflows/ci.yml`.
5. Append `<NEW>` to `OCAML_PATCHES` in `release/versions.sh`.
6. Run the backfill release pass (`docs/RELEASING.md` §5).
