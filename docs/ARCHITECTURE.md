# hamlet-lint architecture

Internal reference for the walker, the analyzer, and the wire contract
between them. For the rule statement and recognised shapes see
`RULE.md`; for install / config / CI see `USAGE.md`; for release
mechanics see `RELEASING.md`.

---

## 1. Why `.cmt` files

The retroactive-widening bug is invisible at the source level: the PPX
expands `[%hamlet.te ...]` and `[%hamlet.ts ...]` into closed rows on
the handler's parameter pattern, but covariant subtyping mutates
upstream's `exp_type` at the call site to satisfy the handler's
universe. Both sides end up structurally compatible — exactly what
hamlet's `('a, +'e, +'r) Hamlet.t` design is meant to allow — and the
typechecker raises no error.

The information the linter needs lives in two places that survive
into `.cmt` files:

- the handler parameter pattern's `pat_type` (the closed row the PPX
  produced), and
- a let-bound upstream's `Texp_ident.value_description.val_type` (the
  *narrow*, pre-widening row the upstream had at its definition).

`.cmt` files are the typed AST the compiler emits under
`_build/default/**/*.cmt`; `compiler-libs` provides
`Cmt_format.read_cmt` to parse them back. The tool is therefore
version-locked against `compiler-libs` (`Typedtree`, `Types`, and
friends drift across OCaml minors without semver); `README.md` §2
covers the version-support policy.

### 1.1 `.cmt` vs `.cmti`

The extractor walks `.cmt` only. Consequence: the linter sees through
`.mli` abstraction. An opaque `.mli` that hides or narrows a row does
not hide the implementation's raw `catch` / `provide` calls from
hamlet-lint.

### 1.2 Pre-installed libraries are invisible

opam ships `.cmi` / `.cmti` / `.cmxa` into `_opam/lib/<pkg>/` but not
`.cmt`, so anything installed from opam is invisible to the walker.
This is shared with every typed-AST tool (merlin, mdx, ppxlib linters,
...).

For **library users**: the linter analyses your own code and passes
silently over opam dependencies. For **library authors**: if your
package uses Hamlet internally and you want a no-widening guarantee,
run hamlet-lint in your own CI before releasing.

### 1.3 Two couplings, two firewalls

The walker is coupled to two moving targets (`compiler-libs` and
hamlet's surface API), but only one needs a compile-time firewall.

**`compiler-libs` (hard coupling).** The walker destructures
`Types.type_expr`, `Typedtree.expression`, `Typedtree.fp_kind`,
`Types.row_field_repr`, etc. These shapes drift across OCaml minors
without semver. Fix: `cppo` preprocesses `extract/compat.cppo.ml`
with `-V OCAML:%{ocaml_version}` and a top-level `#error` guard
fails the build on an unsupported switch (currently 5.4.1 only).
Future drift adds `#if OCAML_VERSION >= (5, 5, 0)` branches
in that single file; nothing else in `extract/` should know about
OCaml versions.

**hamlet (soft coupling).** The walker doesn't link hamlet. It reads
`.cmt` files of projects that use hamlet and matches on string-shaped
data: dotted paths like `Hamlet.Combinators.catch`, the three type
parameters of `('a, 'e, 'r) Hamlet.t`, the labels `~f` / `~h`. New
hamlet vocabulary is just one more pattern in `classify.ml`.

A **structural** hamlet change (e.g. `Hamlet.t` gains a fourth type
parameter) requires touching `upstream.ml`'s `hamlet_slot` and
`classify.ml`'s `mentions_hamlet_t`, but no `#if`. Migration is local
and obvious.

---

## 2. The two binaries, the one contract

```
                ┌──────────────────────────┐
.cmt files ───▶ │   hamlet-lint-extract    │
                │   (compiler-libs side)   │
                └────────────┬─────────────┘
                             │  ND-JSON on stdout
                             │  (one record per recognised call)
                             ▼
                ┌──────────────────────────┐
                │   hamlet-lint            │
                │   (rule + report,        │
                │    pure OCaml)           │
                └────────────┬─────────────┘
                             │  pretty findings on stdout
                             ▼
                       exit 0 / 1
```

`hamlet-lint-extract` (directory `extract/`) is the only part of the
project that touches `compiler-libs`. For every recognised
`Hamlet.Combinators.catch` / `.provide` call it emits a
`candidate` record carrying the handler's declared tag list and
upstream's row tag list. The extractor itself does not apply the
rule.

`hamlet-lint` (directory `analyzer/`) is pure OCaml. It reads
ND-JSON records, applies the rule (`declared \ upstream ≠ ∅`), and
prints findings. Its tests are pure — hand-built schema records, no
fixtures needed.

`hamlet_lint_schema` (directory `schema/`) is the shared contract;
the OCaml types in `schema.ml` are the single source of truth and
both binaries encode/decode the same definitions.

`hamlet_lint_config` (directory `config/`) parses the
`.hamlet-lint.sexp` project config. Both binaries read it
independently (extractor: `targets`, `exclude`; analyzer: `mode`).
No process spawning between them.

### 2.1 Why a wire and not a single binary

Two reasons to keep extractor and analyzer separated:

1. **OCaml-version isolation.** The analyzer compiles unchanged
   against any switch and its tests have no `compiler-libs` surface.
   Rule changes never need a re-walk; walker changes never need a
   rule re-test.
2. **Inspection.** A user who wants to see what the walker actually
   extracted from a fixture can pipe the extractor through `jq`. The
   ND-JSON line format is friendly to grep and shell pipelines.

The cost is a Yojson dependency on both sides and one extra process
per run, both negligible.

---

## 3. The walker (`extract/walker.ml`)

A `Tast_iterator` pass over each `Cmt_format.read_cmt`'s
`Implementation` structure. For every `Texp_apply` whose callee
classifies as `Catch` or `Provide` (see `classify.ml`), the walker:

1. Pulls upstream from the first positional arg
   (`extract_upstream`).
2. Pulls the handler from the `~f` / `~h` labelled arg
   (`extract_handler`).
3. Asks `Handler.universe_tags` for the handler's declared tag
   universe — five recognised shapes, see `RULE.md` §3.3.
4. Asks `Upstream.row_tags` for upstream's row tag list — uses
   `val_type` for `Texp_ident`, `exp_type` otherwise (the documented
   limit, see `LIMITATIONS.md` §1).
5. When both sides are recognised, emits one `S.candidate` record.

Modules:

- `tags.ml` — variant-tag enumeration through `Tvariant` /
  `row_fields` / `row_more`.
- `classify.ml` — callee identification: `Path.name` first, then a
  structural fingerprint via `mentions_hamlet_t`.
- `upstream.ml` — declaration-time type extraction + slot picking.
- `handler.ml` — five-shape extractor for the handler's universe.
- `walker.ml` — iterator setup + per-call dispatch.
- `compat.cppo.ml` — version firewall (currently only an `#error`
  guard).

---

## 4. The analyzer (`analyzer/`)

Three modules:

- `rule.ml` — the rule itself: `check : S.candidate → finding option`,
  `analyze : S.record list → finding list`. Trivial list-set
  difference; testable in isolation against hand-built schema records
  (`test/test_rule.ml`).
- `report.ml` — pretty-print findings to stdout, one multi-line block
  per finding. Format mirrors the upstream PoC so its snapshot
  expectations carry over.
- `main.ml` — CLI (`cmdliner`), schema-version guard, exit code (0
  clean, 1 findings, 2 malformed input).

---

## 5. The ND-JSON contract (`schema/schema.ml`)

Output is **newline-delimited JSON**: one self-contained object per
line with a `"kind"` discriminator. Every stream begins with a
`header`:

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"runtime"}
```

`schema_version` is a single integer (currently `1`); the analyzer
exits 2 on missing or mismatched version. `ocaml_version` and
`generated_at` are diagnostic-only.

Subsequent records are `candidate`:

```json
{
  "kind": "candidate",
  "site_kind": "catch",
  "loc": {"file":"app.ml","line":42,"col":2},
  "declared": ["Console_error","Database_error"],
  "upstream": ["Console_error"]
}
```

- `site_kind`: `"catch"` (slot `'e`) or `"provide"` (slot `'r`).
- `loc`: the application site, where the finding will land.
- `declared`: handler's declared universe in source order.
- `upstream`: upstream's row tags in source order.

The analyzer applies `declared \ upstream` and emits a finding when
the difference is non-empty.

### 5.1 Canonical mode

`hamlet-lint-extract --canonical` sorts candidates by
`(file, line, col)` and sets `generated_at="canonical"`, making the
output stable across runs. Use it for snapshot tests.

---

## 6. Failure mode

The walker always fails in the safe direction: unrecognised shapes
are skipped silently. The analyzer emits findings only when both
declared and upstream were extracted, and the difference is
non-empty. Net result: false negatives only, never false positives.

The two known gaps (inline upstream, exotic handler shapes) are
documented in `LIMITATIONS.md`.
