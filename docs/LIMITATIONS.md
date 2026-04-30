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

## 8. Multi-callback combinators only inspect their primary row probe

`catch_filter` and `catch_cause_filter` carry the row on more than one
callback. The linter inspects only the primary one (`~filter` for both),
so a `[%hamlet.te ...]` annotation placed exclusively on `~on_no_match`
or on `catch_cause_filter`'s `~f` second parameter is silent.

In practice OCaml unifies the row variable across callbacks, so
annotating any of them constrains the same `'e`; the gap matters only
when `~filter` is unannotated or naturally narrow and the user widens
solely on the secondary callback.

**Fix:** put the `[%hamlet.te ...]` annotation on `~filter`.

## 9. Let-bound partial application

The walker unstages an inline `eff |> catch ~f:H` automatically, but a
let-bound partial breaks the chain.

```ocaml
let p = Hamlet.Combinators.catch eff in
p ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Fix:** call the combinator in one application.
