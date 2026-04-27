# hamlet-lint architecture

Internal reference. Rule statement in `RULE.md`. Install/CI in
`USAGE.md`. Release process in `RELEASING.md`.

## 1. Why `.cmt`

The retroactive-widening bug is invisible at source level: PPX
expands `[%hamlet.te ...]` into a closed row on the handler's pattern;
covariant subtyping then mutates upstream's `exp_type` at the call
site to satisfy that row. Both sides become structurally compatible
and the typechecker accepts.

What survives into `.cmt` and we need:

- handler param's `pat_type` (the closed row PPX produced).
- let-bound upstream's `Texp_ident.value_description.val_type` (the
  *narrow*, pre-widening row).

`compiler-libs.Cmt_format.read_cmt` parses `.cmt`. The walker is
version-locked to `compiler-libs` (drift across OCaml minors without
semver).

**`.cmt` vs `.cmti`**: walker reads `.cmt` only — sees through `.mli`
abstraction.

**Pre-installed opam libs invisible**: opam ships `.cmti` not `.cmt`.
Library authors should run hamlet-lint in their own CI.

## 2. Two binaries, one wire

```
.cmt → hamlet-lint-extract → ND-JSON stdout → hamlet-lint → findings + exit 0/1
       (compiler-libs side)                   (pure OCaml)
```

- **`extract/`** (lib `hamlet_lint_extract` + exe `hamlet-lint-extract`):
  the only `compiler-libs` consumer. Walks `.cmt`, classifies calls,
  emits `candidate` records. Does NOT apply the rule.
- **`analyzer/`** (lib `hamlet_lint_analyzer` + exe `hamlet-lint`):
  pure OCaml. Reads ND-JSON, applies `declared \ upstream`, prints
  findings.
- **`schema/`**: the wire contract (`header` + `candidate`), Yojson
  codecs, single source of truth for both binaries.
- **`config/`**: parses `.hamlet-lint.sexp`. Both binaries read it
  independently (no IPC).

**Why split**: OCaml-version isolation (analyzer compiles unchanged
on any switch; rule changes need no re-walk), and inspection (`jq` on
the ND-JSON for debugging fixtures).

## 3. Walker (`extract/`)

`Tast_iterator` over each `Cmt_format.read_cmt`'s `Implementation`.
For every `Texp_apply` whose callee classifies as `Catch` / `Provide`:

1. `extract_upstream` — first positional arg.
2. `extract_handler` — `~f` / `~h` arg.
3. `Handler.universe_tags` — handler's declared tags (5 shapes, see
   `RULE.md` §3.3).
4. `Upstream.row_tags` — upstream's row tags. Uses `val_type` for
   `Texp_ident`, recursive residual for chained inline monitored
   combinators (see `RULE.md` §3.4), `exp_type` otherwise.
5. Emits one `Schema.candidate`.

Modules:

| File             | Responsibility                                                           |
|------------------|--------------------------------------------------------------------------|
| `tags.ml`        | Variant-tag enumeration via `Tvariant` / `row_fields` / `row_more`       |
| `classify.ml`    | Callee identification: canonical `Path.name` + structural fingerprint    |
| `propagate.ml`   | Pure-propagate detectors (catch `fail`, provide `give`/`need`)           |
| `upstream.ml`    | `val_type` extraction, slot picking, `residual` recursion, `unstage_apply` |
| `handler.ml`     | Five-shape extractor for handler universe                                |
| `walker.ml`      | Tast iterator + per-call dispatch (direct + unstaged)                    |
| `compat.cppo.ml` | OCaml-version firewall (`#error` guard, currently 5.4.1 only)            |

The pipe form `eff |> catch ~f:H` produces a staged `Texp_apply`
(partial-then-apply with `Omitted` slots). `unstage_apply` splices
outer positional args into inner `Omitted` slots so classification
works on both direct and pipe forms.

## 4. Analyzer (`analyzer/`)

| File         | Responsibility                                                          |
|--------------|-------------------------------------------------------------------------|
| `rule.ml`    | `check : candidate → finding option` = list-set difference              |
| `report.ml`  | Pretty-print findings, mirrors upstream PoC format                      |
| `main.ml`    | CLI (`cmdliner`), schema-version guard, exit codes 0/1/2                |

Trivially testable in isolation against hand-built schema records
(`test/test_rule.ml`) — no fixtures needed.

## 5. Wire contract (`schema/`)

ND-JSON. One self-contained record per line, `"kind"` discriminator.
Header always first:

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"runtime"}
```

Then `candidate` records:

```json
{
  "kind": "candidate",
  "site_kind": "catch",
  "combinator": "catch",
  "loc": {"file":"app.ml","line":42,"col":2},
  "declared": ["Console_error","Database_error"],
  "upstream": ["Console_error"]
}
```

`schema_version` integer; analyzer exits 2 on missing/mismatched.
`--canonical` sorts by `(file, line, col)` and sets
`generated_at="canonical"` for stable snapshots.

## 6. Two couplings, one firewall

**`compiler-libs` (hard)**: walker destructures `Types.type_expr`,
`Typedtree.expression`, etc. — drifts across OCaml minors.
`extract/compat.cppo.ml` is the firewall: cppo with
`-V OCAML:%{ocaml_version}` + top-level `#error` guard. Future drift
adds `#if OCAML_VERSION >= (5, 5, 0)` branches there only.

**hamlet (soft)**: walker doesn't link hamlet. Reads `.cmt` of
projects that use it, matches on string-shaped data (paths, type
parameter counts, label names). New combinators = one more pattern
in `classify.ml`. A *structural* hamlet change (e.g. `Hamlet.t` gains
a 4th param) touches `upstream.ml::hamlet_slot` and
`classify.ml::mentions_hamlet_t` — local and obvious, no `#if`.

## 7. Failure mode

Walker fails safely: unrecognised shapes are skipped silently.
Analyzer emits findings only when both sides were extracted and the
difference is non-empty. **False negatives only, never false
positives.** Known gaps in `LIMITATIONS.md`.
