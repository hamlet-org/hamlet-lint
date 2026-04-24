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

(* ========== Layer.catch ========== *)

(* lc1 - GOOD: Layer.catch handler covers exactly upstream's errors *)
let lc1_layer_catch_narrow () =
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.failure (`Console_error "boom"))
  in
  Hamlet.Layer.catch lay ~f:(fun (x : [%hamlet.te Console]) ->
      match x with
      | `Console_error _ ->
          Hamlet.Layer.make Console.Tag.key
            (Hamlet.Combinators.failure (`Console_error "fallback")))

(* lc2 - BAD: Layer.catch handler declares Console + Database; upstream emits only Console *)
let lc2_layer_catch_widening () =
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.failure (`Console_error "boom"))
  in
  Hamlet.Layer.catch lay ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with
      | `Console_error _ | `Connection_error _ | `Query_error _ ->
          Hamlet.Layer.make Console.Tag.key
            (Hamlet.Combinators.failure (`Console_error "fallback")))

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
   Curried handler, target is a Layer.t. Since hamlet d62acb7 made
   Layer.t covariant in 'e and 'r, the typechecker keeps the target's
   row narrow at val_type while widening at the call site — same
   visibility as Hamlet.t for Combinators.provide. *)

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

(* lpl2 - BAD: handler declares Console + Database, target needs only Console.
   Covariance on Layer.t lets the typechecker keep target's row narrow at
   val_type while widening at the call site, exposing the bug. *)
let lpl2_provide_to_layer_widening () =
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
    ~h:(fun impl (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w impl
      | [%hamlet.propagate_s] -> .)
    target

(* lpm2 - BAD: env-row handler declares Console + Database, target needs only Console *)
let lpm2_provide_merge_to_layer_widening () =
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
    ~h:(fun env (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w env#console
      | [%hamlet.propagate_s] -> .)
    target
