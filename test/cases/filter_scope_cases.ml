(** Fixtures for the new combinators whose row annotation sits on a labeled
    handler parameter other than [~f] / the curried second slot of
    [Layer.provide_*]:

    - [Combinators.catch_filter]: row on [~filter] (single-arg)
    - [Combinators.provide_scope]: row on [~handler] curried second slot
      ([Scope_core.t -> 'r_in -> _]) *)

open Hamlet_test_services

(* ============================================================ *)
(* Combinators.catch_filter                                     *)
(* ============================================================ *)

(* cf1 - GOOD: catch_filter ~filter parameter declares exactly Console *)
let cf1_catch_filter_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_filter eff
    ~filter:(fun (e : [%hamlet.te Console]) ->
      match e with `Console_error _ -> Some ())
    ~f:(fun () -> return ())
    ~on_no_match:(fun _cause -> return ())

(* cf2 - BAD: ~filter declares Console + Database; upstream emits only Console *)
let cf2_catch_filter_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_filter eff
    ~filter:(fun (e : [%hamlet.te Console, Database]) ->
      match e with
      | `Console_error _ | `Connection_error _ | `Query_error _ -> Some ())
    ~f:(fun () -> return ())
    ~on_no_match:(fun _cause -> return ())

(* ============================================================ *)
(* Combinators.provide_scope                                    *)
(* ============================================================ *)

(* ps1 - GOOD: provide_scope handler discharges exactly Console *)
let ps1_provide_scope_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  provide_scope eff ~handler:(fun _scope (x : [%hamlet.ts Console]) ->
      match x with #Console.Tag.r as w -> Console.Tag.give w (failwith "C"))

(* ps2 - BAD: provide_scope handler declares Console + Database; upstream summons only Console *)
let ps2_provide_scope_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  provide_scope eff ~handler:(fun _scope (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | [%hamlet.propagate_s] -> .)
