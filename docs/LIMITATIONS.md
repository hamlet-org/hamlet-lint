# Limitations

What hamlet-lint does *not* catch.

## 1. Inline upstream built from non-monitored operations

When an inline upstream is constructed from anything **other than** one
of the twelve monitored combinators (the `catch` / `provide` / `map_error`
families and their `Layer.*` siblings — see §3 for the full unmonitored
list), the linter falls back to widened `exp_type`. No finding.

(Chains of monitored combinators inline — `eff |> catch ~f:H |> catch
~f:H`, `provide (provide eff ~handler:...) ~handler:...`, mixed
`catch∘provide`/`Layer.provide_to_*` — ARE detected via the recursive
residual.)

```ocaml
(* not detected: let* expands to `chain`, not monitored *)
catch (let* (module C) = Console.Tag.summon () in C.print_endline "go")
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Fix:** bind the non-monitored upstream first.

```ocaml
let eff = let* (module C) = Console.Tag.summon () in C.print_endline "go" in
catch eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

## 2. Handler shapes the walker doesn't pattern-match

Five recognised shapes (param-pat annotation, function-cases annotation,
scrutinee annotation, named ident, single apply-built). Anything else
returns no candidate.

```ocaml
catch eff ~f:(let prep () = () in prep (); fun x -> ...)
```

**Fix:** extract the handler.

```ocaml
let h x = ... in
catch eff ~f:h
```

## 3. Combinators outside the 12 monitored

`bind`, `pure`, `merge_all`, `try_catch`, `or_die`, `tap`, `Layer.make`,
`Layer.fresh`, `Layer.unwrap`, `ensuring`, `sandbox`, `sandbox_cause`,
etc. carry no row-declaring handler. Silent by design.

## 4. OCaml version coupling

The walker links `compiler-libs.common`. Currently OCaml 5.4.1 only.
`extract/compat.cppo.ml` is the firewall.

## 5. Computed combinator references

A callee built by an expression (not a plain identifier) is not
recognised.

```ocaml
let combinator = if production then catch else provide in
combinator eff ~f:...
```

## 6. Aliased Hamlet primitives

The chained-residual detector recognises `Hamlet.Combinators.fail`,
`Hamlet.Dispatch.need`, and `<X>.Tag.give` only by canonical path
(plus parent-module = `Tag` for `give`). Aliases are NOT followed.

```ocaml
(* not detected — open shortens the path *)
let open Hamlet.Combinators in
catch (catch eff ~f:(fun x -> match x with `Console_error _ as e -> fail e))
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)

(* not detected — value alias renames *)
let raise_err = Hamlet.Combinators.fail in
... raise_err e ...

(* not detected — module alias renames *)
let module CT = Console.Tag in
... CT.give w impl ...
```

**Fix:** use canonical paths in handler arms, or let-bind the inner
combinator's result.

## 7. Local aliasing of the combinator itself

A combinator bound to a local name escapes path-based classification.

```ocaml
let c = Hamlet.Combinators.catch in
c eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Fix:** call the combinator directly.

```ocaml
Hamlet.Combinators.catch eff
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

## 8. `catch_filter` / `catch_cause_filter` — widening on a remapping
filter's `'match_` is not detected

`catch_filter` / `catch_cause_filter` have three callbacks; only one
type variable is shared with upstream (`'e`):

- `~filter`'s parameter — `'e` (or `'e Cause.t` for the cause variant)
- `~on_no_match`'s parameter — `'e Cause.t`
- `~f`'s second parameter on `catch_cause_filter` — `'e Cause.t`
- `~f`'s first parameter — `'match_`, the type filter returns wrapped
  in `Some _`. Independent of `'e` in general.

Annotations on any of the first three positions propagate to the
others through OCaml unification: the linter reads `~filter`'s
`pat_type` (post-unification), so a widening on any of them is
caught.

The genuine gap is `~f`'s first parameter (`'match_`) **when filter
remaps types**. Concretely:

```ocaml
(* filter is identity-typed: 'match_ = 'e, gap closed by unification *)
catch_filter eff
  ~filter:(fun e -> Some e)
  ~f:(fun (_m : [%hamlet.te Console, Database]) -> ...)  (* CAUGHT *)
  ~on_no_match:...

(* filter remaps: 'match_ independent of 'e, gap real *)
catch_filter eff
  ~filter:(fun e ->
    match e with `Console_error s -> Some (`Console_error s) | _ -> None)
  ~f:(fun (_m : [%hamlet.te Console, Database]) -> ...)  (* SILENT *)
  ~on_no_match:...
```

In the second form, `'match_` is closed by `~f`'s annotation but
filter only ever emits `` `Console_error ``; the `Connection_error`
and `Query_error` arms of `~f` are dead. Catching this would require
inferring the tag set actually produced by filter's body, symmetric
to the existing pure-give detector for `provide` handlers but on
filter's output side.

**Fix:** put the `[%hamlet.te ...]` annotation on `~filter` or on
`~on_no_match` — both probe `'e` directly and the linter will catch
any retroactive widening on the upstream row.

## 9. Let-bound partial application

The walker unstages an inline `eff |> catch ~f:H` automatically, but a
let-bound partial breaks the chain.

```ocaml
let p = Hamlet.Combinators.catch eff in
p ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Fix:** call the combinator in one application.
