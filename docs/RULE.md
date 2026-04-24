# The retroactive-widening rule

## 1. Statement

For every application of `Hamlet.Combinators.catch` or
`.provide` whose handler the linter can recognise, let:

- `declared` = the set of tags in the handler's
  `[%hamlet.te ...]` (catch) or `[%hamlet.ts ...]` (provide)
  annotation, after the PPX has expanded it into a closed row;
- `upstream` = the set of tags actually carried by upstream's
  effect at the slot relevant to the combinator
  (`'e` for catch, `'r` for provide), read from the
  upstream value's *declaration-time* type when possible
  (see §3.2).

The rule is the list-set difference:

> if `declared \ upstream ≠ ∅`, the call is a finding; the
> extra tags are reported.

OCaml's row subtyping cannot reject this at compile time given
hamlet's covariant `('a, 'e, 'r) Hamlet.t` design. The check
runs after compilation on the typechecker's `.cmt` output.

## 2. Combinator surface

Two slot families (`'e` errors / `'r` services) and two handler arities
(single-arg `~f` / `~h:(x -> ...)` and curried `~h:(svc -> x -> ...)`):

| Combinator                                | Slot           | Handler arity | PPX key            |
|-------------------------------------------|----------------|---------------|--------------------|
| `Hamlet.Combinators.catch`                | `'e` (errors)  | single        | `[%hamlet.te ...]` |
| `Hamlet.Combinators.map_error`            | `'e` (errors)  | single        | `[%hamlet.te ...]` |
| `Hamlet.Combinators.provide`              | `'r` (services)| single        | `[%hamlet.ts ...]` |
| `Hamlet.Layer.catch`                      | `'e` (errors)  | single        | `[%hamlet.te ...]` |
| `Hamlet.Layer.provide_to_effect`          | `'r` (services)| curried       | `[%hamlet.ts ...]` |
| `Hamlet.Layer.provide_to_layer`           | `'r` (services)| curried       | `[%hamlet.ts ...]` |
| `Hamlet.Layer.provide_merge_to_layer`     | `'r` (services)| curried       | `[%hamlet.ts ...]` |

`'a` (the success type) is never inspected — widening on `'a` is
a different bug class and out of scope here.

**Curried handlers**: the `Layer.provide_to_*` combinators take
`~h:(svc -> r_in -> dispatch)`. The row annotation sits on the
*second* parameter; the linter strips one outer
`Texp_function` layer before applying the five-shape extractor.

## 3. Recognised shapes

### 3.1 Callee

The callee is recognised when either:

1. `Path.name` of the called identifier equals one of the entries in
   `single_arg_paths` / `curried_paths` (e.g.
   `Hamlet.Combinators.catch`, `Hamlet.Layer.provide_to_effect`), or
2. the last segment of the path matches a known bare name (`catch` /
   `provide` / `map_error` / `provide_to_*`) *and* both:
   - the value's type structurally mentions a 3-arg `Hamlet.t`
     constructor whose root identifier is `Hamlet` or `Hamlet__*`
     (the dune-mangled wrapper), and
   - the callee provably comes from Hamlet — either the callee path
     itself is rooted in `Hamlet` / `Hamlet__*` (covers
     `let open Hamlet.Combinators in catch ...`) or the callee's
     `value_description.val_loc` points at `hamlet.mli` /
     `hamlet.ml` (covers
     `let module HC = Hamlet.Combinators in HC.catch`, where the
     path root is the local alias `HC` rather than `Hamlet`).

The provenance gate rules out user-defined helpers that happen to be
named `catch` / `provide` / ... and operate on `Hamlet.t` (regression
test: `test/cases/edge_cases.ml::e11`).

### 3.2 Upstream

Upstream is the first positional argument of the application.
Its row tags are read from:

- The `Texp_ident`'s `value_description.val_type` when upstream
  is a let-bound variable. This is the **pre-widening** narrow
  row, before any covariant subtyping mutated `exp_type` at the
  call site.
- The expression's `exp_type` otherwise (inline upstream).
  This is already widened — see §5.

### 3.3 Handler

The handler is the `~f` or `~h` labelled argument. Five shapes
are tried in order; first to yield a non-empty universe wins:

1. **Param-pat annotation.**
   `fun (x : [%hamlet.te A, B]) -> ...`
   The PPX has expanded the attribute into a closed-row
   `pat_type` on the first parameter pattern.

2. **Function-cases annotation.**
   `function | ... | ... : [%hamlet.te A, B] -> _`
   Read tags from the first case's `c_lhs.pat_type`.

3. **Scrutinee annotation.**
   `fun x -> match (x : [%hamlet.te A, B]) with ...`
   Read tags from the first match case's `c_lhs.pat_type`.

4. **Named handler.**
   `~f:handle_wide` or `~f:Module.handle`
   Walk `val_type`, take the first arrow's domain row.

5. **Apply-built handler.**
   `~f:(make_handler args)`
   Same as 4 but on `exp_type`.

## 4. Wire format

The extractor emits one ND-JSON `candidate` record per recognised
call, regardless of whether the rule fires. The analyzer applies
the rule and prints findings. Schema:

```json
{
  "kind": "candidate",
  "site_kind": "catch" | "provide",
  "combinator": "catch" | "map_error" | "Layer.catch" | "Layer.provide_to_effect" | ...,
  "loc": { "file": "...", "line": N, "col": N },
  "declared": ["Tag1", "Tag2", ...],
  "upstream": ["Tag1", ...]
}
```

`site_kind` tells you which slot was inspected (`'e` for catch, `'r`
for provide). `combinator` is the short name of the actual callee, so
the report can name precisely which combinator fired.

A leading `header` record carries `schema_version`. The analyzer
exits 2 on a missing or version-mismatched header.

## 5. Known limit: inline upstream

Inline upstream (no let-binding) has no `Texp_ident`, so we
fall back to `exp_type`. By the time the typechecker stored
`exp_type` the row has already been widened to satisfy the
handler's annotation — declared and upstream will compare
equal and no finding is emitted. **This is a documented
false negative.** The workaround is trivial: bind the
upstream:

```ocaml
let eff = ... in catch eff ~f:...
```

Once let-bound, `Texp_ident.val_type` carries the narrow row
and the rule fires correctly.

## 6. Tag enumeration semantics

Tags counted as "present in the row" are those whose
`row_field_repr` is `Rpresent _` or `Reither _`. `Rabsent` is
ignored. `Reither` counts as present because in our context it
means the row structurally allows the tag, even if conjunctive
constraints have not finalised it.
