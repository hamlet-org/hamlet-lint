# The retroactive-widening rule

## 1. Statement

For every monitored combinator call:

- `declared` = tags from the handler's `[%hamlet.te ...]` /
  `[%hamlet.ts ...]` annotation, after PPX expansion to a closed row.
- `upstream` = tags actually carried at the relevant slot of the
  upstream's `Hamlet.t` / `Layer.t` (`'e` for catch, `'r` for
  provide), read from the upstream's *declaration-time* type when
  possible (§3.2).

> If `declared \ upstream ≠ ∅`, the call is a finding. Extra tags
> are reported.

OCaml's covariant `('a, +'e, +'r) Hamlet.t` lets row widening
type-check at compile time. The check runs post-compile on `.cmt`.

## 2. Monitored combinators

| Combinator                            | Slot | Arity   | PPX key            |
|---------------------------------------|------|---------|--------------------|
| `Hamlet.Combinators.catch`            | `'e` | single  | `[%hamlet.te ...]` |
| `Hamlet.Combinators.map_error`        | `'e` | single  | `[%hamlet.te ...]` |
| `Hamlet.Combinators.provide`          | `'r` | single  | `[%hamlet.ts ...]` |
| `Hamlet.Layer.catch`                  | `'e` | single  | `[%hamlet.te ...]` |
| `Hamlet.Layer.provide_to_effect`      | `'r` | curried | `[%hamlet.ts ...]` |
| `Hamlet.Layer.provide_to_layer`       | `'r` | curried | `[%hamlet.ts ...]` |
| `Hamlet.Layer.provide_merge_to_layer` | `'r` | curried | `[%hamlet.ts ...]` |

`'a` (success type) is never inspected.

**Curried** = handler is `svc -> r_in -> dispatch`; the row annotation
sits on the *second* parameter. The walker strips one outer
`Texp_function` layer (`~peel:1`).

## 3. Recognised shapes

### 3.1 Callee

The callee is recognised when either:

1. `Path.name` matches a canonical entry (e.g. `Hamlet.Combinators.catch`), or
2. `Path.last` matches a bare name (`catch`, `provide`, `map_error`,
   `provide_to_*`) AND both:
   - the value's type structurally mentions a 3-arg `Hamlet.t` rooted
     in `Hamlet` / `Hamlet__*`, AND
   - the callee provably comes from Hamlet — either path-rooted in
     `Hamlet` (covers `let open Hamlet.Combinators in catch`) or
     `vd.val_loc` in `hamlet.mli`/`hamlet.ml` (covers
     `let module HC = Hamlet.Combinators in HC.catch`).

The provenance gate prevents misclassifying user helpers named like
combinators (regression: `edge_cases.ml::e11`).

### 3.2 Upstream

First positional argument. Tags read from:

- **`Texp_ident`** → `value_description.val_type` (pre-widening
  narrow row). The whole point.
- **`Texp_apply` of another monitored combinator** → recursive
  residual computation through the inner combinator (handles chained
  inline catch/provide and `eff |> catch ~f:H` pipe form). See §3.4.
- **anything else** → `exp_type` (already widened — see
  `LIMITATIONS.md` §1).

### 3.3 Handler

Five shapes, tried in order; first non-empty wins:

1. **Param-pat annotation:** `fun (x : [%hamlet.te A, B]) -> ...`
2. **Function-cases annotation:** `function | ... : [%hamlet.te A, B] -> _`
3. **Scrutinee annotation:** `fun x -> match (x : [%hamlet.te A, B]) with ...`
4. **Named handler:** `~f:handle_wide` — walk `val_type` arrow domain.
5. **Apply-built handler:** `~f:(make_handler args)` — same on `exp_type`.

### 3.4 Recursive residual (chained inline)

When upstream is itself a `Texp_apply` of a monitored combinator,
the walker computes the inner's residual row instead of falling back
to widened `exp_type`:

| Combinator | Slot 1 (errors)        | Slot 2 (services)            |
|------------|------------------------|------------------------------|
| catch      | handler-driven         | pass-through (recurse)       |
| map_error  | handler codomain (n/a) | pass-through (recurse)       |
| provide    | pass-through (recurse) | handler-driven               |
| Layer.*    | (same as above)        | (same as above)              |

Handler-driven cases recognised:

- **catch** with pure-propagate handler (every arm is `failure(alias)`,
  including cross-CU `failure(<__Hamlet_rest_*>.expose_X (alias :> _))`):
  residual = inner upstream's row.
- **provide** with handler whose every arm is `Dispatch.need(alias)`
  (re-emit) or `<X>.Tag.give(alias) _` (discharge): residual = inner
  upstream's row ∖ (union of give-tags). Mixed give+need is the
  common idiom and works.

The pipe form `eff |> catch ~f:H` produces a staged `Texp_apply`
(partial-then-apply with `Omitted` slots); the walker unstages it
into the canonical direct shape before classification.

Anything else → fallback to widened `exp_type`. Sound posture:
false negatives only, never false positives.

## 4. Wire format

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"runtime"}
{"kind":"candidate","site_kind":"catch","combinator":"catch",
 "loc":{"file":"app.ml","line":42,"col":2},
 "declared":["Console_error","Database_error"],
 "upstream":["Console_error"]}
```

`site_kind` = which slot was inspected. `combinator` = short callee
name for the report. The analyzer exits 2 on missing/mismatched
header.

## 5. Tag enumeration semantics

Tags counted as "present" are those whose `row_field_repr` is
`Rpresent _` or `Reither _`. `Rabsent` ignored. `Reither` counts
because in our context it means the row structurally allows the tag
even if conjunctive constraints have not finalised it.
