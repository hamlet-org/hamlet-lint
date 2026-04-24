(** Fixtures for combinators added beyond the original PoC pair:
    - [Combinators.map_error] (single-arg handler, errors slot)
    - [Layer.provide_to_effect] (curried handler [svc -> r_in -> dispatch],
      services slot)

    [Layer.catch] / [Combinators.catch] / [Combinators.provide] share the
    single-arg-handler code path with the existing widening_cases fixtures
    and need no separate fixture; constructing a [Layer.t] with a row narrow
    enough to expose the bug requires a full service implementation, which is
    out of proportion. *)

open Hamlet_test_services

(* ========== Combinators.map_error ========== *)

(* m1 - GOOD: handler declares only what upstream emits *)
let m1_map_error_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  map_error eff ~f:(fun (x : [%hamlet.te Console]) ->
      match x with `Console_error s -> `Wrapped s)

(* m2 - BAD: handler declares Console + Database; upstream only Console *)
let m2_map_error_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  map_error eff ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with
      | `Console_error s -> `Wrapped s
      | `Connection_error s -> `Wrapped s
      | `Query_error s -> `Wrapped s)

(* ========== Layer.provide_to_effect (curried handler) ========== *)

(* lpe1 - GOOD: handler declares exactly upstream's services *)
let lpe1_provide_to_effect_narrow () =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.return (failwith "C"))
  in
  Hamlet.Layer.provide_to_effect ~s:lay
    ~h:(fun impl (x : [%hamlet.ts Console]) ->
      match x with #Console.Tag.r as w -> Console.Tag.give w impl)
    eff

(* lpe2 - BAD: handler's services universe is wider than upstream's *)
let lpe2_provide_to_effect_widening () =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.return (failwith "C"))
  in
  Hamlet.Layer.provide_to_effect ~s:lay
    ~h:(fun impl (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w impl
      | [%hamlet.propagate_s] -> .)
    eff

(* ========== Layer.provide_to_layer / provide_merge_to_layer ==========
   These two combinators take the same curried handler shape as
   provide_to_effect but the upstream is a target Layer.t (not a
   Hamlet.t). When the target is built via Layer.make, OCaml's value
   restriction leaves its row variables weak ('_r) and the typechecker
   widens them to the handler's annotation BEFORE the linter reads
   val_type — same fundamental limit as inline upstream
   (see docs/LIMITATIONS.md §1).

   Result: the classifier correctly dispatches to these combinators
   (Curried-Provide), the candidate is emitted, but declared = upstream
   so no finding fires. The two GOOD fixtures below prove the dispatch
   doesn't false-positive; a BAD fixture cannot be constructed without
   a real service implementation pinning the row. *)

let lpl_provide_to_layer_narrow () =
  let target =
    Hamlet.Layer.make Logger.Tag.key
      (let open Hamlet.Combinators in
       let* (module C) = Console.Tag.summon () in
       let* () = C.print_endline "build logger" in
       Hamlet.Combinators.return (failwith "L"))
  in
  let dep =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.return (failwith "C"))
  in
  Hamlet.Layer.provide_to_layer ~s:dep
    ~h:(fun impl (x : [%hamlet.ts Console]) ->
      match x with #Console.Tag.r as w -> Console.Tag.give w impl)
    target

let lpm_provide_merge_to_layer_narrow () =
  let target =
    Hamlet.Layer.make Logger.Tag.key
      (let open Hamlet.Combinators in
       let* (module C) = Console.Tag.summon () in
       let* () = C.print_endline "build logger" in
       Hamlet.Combinators.return (failwith "L"))
  in
  let env_build =
    let open Hamlet.Combinators in
    return
      (object
         method console : (module Console.S) = failwith "C"
      end)
  in
  Hamlet.Layer.provide_merge_to_layer ~s:env_build
    ~h:(fun env (x : [%hamlet.ts Console]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w env#console)
    target
