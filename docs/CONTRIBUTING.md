# Contributing to hamlet-lint

Internal reference for common extension tasks. For architecture and
the wire contract see `ARCHITECTURE.md`; for the release model see
`RELEASING.md`.

---

## 1. How to add a new test case

Two layers:

- **Rule tests** in `test/test_rule.ml` drive `Rule.check_*` directly
  with hand-built schema records. The right place for rule semantics
  (wildcard suppression, body-introducer case, latent join) — no
  compiler-libs, no fixtures. Use `mk_services_site` /
  `mk_errors_site` / `mk_arm` helpers and assert via `check_tags`.
- **End-to-end fixtures** in `test/cases/<name>/`, exercised by
  `test/test_e2e.ml`. See `test/cases/README.md` for the fixture
  layout and the `make run/ndjson/debug FIXTURE=<name>` helpers.

Run `dune runtest`; regenerate snapshots with `dune promote`.

---

## 2. How to add support for a new combinator

If Hamlet grows a ninth handler-style combinator, hook it in like
this:

1. Add a constructor to `combinator_kind` in `schema/schema.ml` and
   update the `combinator_kind_to_string` / `_of_string` pair
   symmetrically.
2. Extend `match_combinator` in `extract/walker.ml` with a suffix
   match resolving the dotted name to the new kind.
3. Teach `concrete_of_apply` how to split the new combinator's
   arguments: subject effect, handler, lambdas to peel, and which
   row is touched.
4. If the body shape is novel (not `give` / `need`,
   `failure` / `success`, or a pure variant), add a
   `classify_<new>_arm` and wire it into `arms_of_cases`.
5. Add a rule test to `test_rule.ml` and an e2e fixture under
   `test/cases/<new_combinator>/` covering stale and clean cases.
6. Update the `README.md` §3 table with the new row.
