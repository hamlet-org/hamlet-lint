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

#### The problem

§3.2 says we read upstream's narrow row from `Texp_ident.val_type`.
That trick depends on upstream being a let-bound name. When upstream
is built **inline** as another monitored call, there's no
`Texp_ident` to read — we have a `Texp_apply`, and its `exp_type`
has already been widened by the outer's annotation. So this used to
escape detection:

```ocaml
(* outer declares Console+Database; inner only re-emits Console.
   Without recursion: linter sees upstream = [Console, Database]
   (widened) and finds nothing extra. *)
catch
  (catch eff ~f:(fun (x : [%hamlet.te Console]) ->
       match x with [%hamlet.propagate_e] -> .))
  ~f:(fun (x : [%hamlet.te Console, Database]) ->
       match x with [%hamlet.propagate_e] -> .)
```

Same for the pipe form `eff |> catch ~f:H1 |> catch ~f:H2`: the
outer's upstream is a `Texp_apply`, not a `Texp_ident`.

#### The fix

When upstream is a `Texp_apply` of a monitored combinator, recurse:
ask "what row would the inner combinator actually produce on the slot
the outer cares about?" — call this the **residual** of the inner.

Recursion stops at:

- a `Texp_ident` → read `val_type` as in §3.2.
- anything else → fall back to widened `exp_type` (same as before).

What residual the inner produces depends on whether the inner's own
operation touches the slot the outer cares about:

- **Pass-through slot**: the inner combinator doesn't touch this
  slot. `provide` doesn't change errors; `catch` doesn't change
  services. So the residual on a pass-through slot is just the
  inner upstream's residual on the same slot — recurse on the
  inner's positional arg.
- **Touched slot**: the inner combinator's handler determines what
  comes out. We can compute residual exactly only when the handler
  matches one of two known shapes (below); otherwise fall back to
  widened.

Per-combinator slot effect:

| Combinator | Slot 1 (errors)        | Slot 2 (services)         |
|------------|------------------------|---------------------------|
| catch      | touched                | pass-through              |
| map_error  | touched (not handled)  | pass-through              |
| provide    | pass-through           | touched                   |
| Layer.*    | (same as above)        | (same as above)           |

#### Recognised handler shapes for touched slots

**catch with pure-propagate handler.** Every arm is
`failure(<the alias bound by the pattern>)` — i.e. "match the tag,
re-raise it unchanged". Semantically a row no-op: the handler emits
exactly what it receives. Residual = inner upstream's residual.

This is exactly what `[%hamlet.propagate_e]` PPX-expands to. The
cross-CU expansion wraps the alias in `<__Hamlet_rest_X>.expose_Y
(alias :> _)` before passing to `failure`; the walker recognises both
shapes.

**provide with give/need handler.** Every arm is one of:

- `<X>.Tag.give(alias) impl` — "discharge this service by handing in
  an implementation". Removes the matched tag from the residual.
- `Hamlet.Dispatch.need(alias)` — "I still need this service,
  forward it". Pass-through, contributes nothing.

Residual on slot 2 = inner upstream's residual on slot 2 ∖ (union of
tags discharged by `give` arms). Mixed give+need is the common idiom
(provide some services, propagate the rest); it works.

`[%hamlet.propagate_s]` expands to all-need arms; explicit
`X.Tag.give w impl` arms come from user code.

#### Pipe form

`eff |> catch ~f:H` does NOT inline at typedtree level when `catch`
is partially applied: it produces a staged `Texp_apply` whose callee
is itself a `Texp_apply` of `catch` with the upstream slot marked
`Omitted`. The walker unstages this — splices the outer's positional
arg into the inner partial's `Omitted` slot — to get a canonical
direct call shape, then classifies as usual. So pipe and nested
forms are handled identically.

#### Soundness

If the handler shape isn't recognised → fallback to widened
`exp_type`. The widened type is an upper bound on what's actually
emitted, so `declared ∖ upstream` is a lower bound on real extras.
**False negatives only, never false positives.** This invariant
holds across the whole recursion.

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
