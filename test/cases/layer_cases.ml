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
