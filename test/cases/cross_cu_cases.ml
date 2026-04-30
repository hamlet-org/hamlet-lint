(** Cross-CU widening fixtures.

    [RemoteCache] is declared in [test/support/remote_cache.ml] with the
    [@@rest_cross_cu] attribute, in its own compilation unit. The PPX
    at the consumer site has no entry for it in the local
    [service_errors] table and resolves the propagate arm via the
    producer's synthesised [__Hamlet_rest_RemoteCache__] module.

    These cases exercise that the linter correctly walks
    [Texp_apply (catch, ...)] / [Texp_apply (provide, ...)] when
    the upstream [Hamlet.t]'s row is built from cross-CU
    PPX-generated aliases. *)

open Hamlet_test_services

(* xc1 - GOOD: handler covers exactly RemoteCache's full error universe *)
let xc1_cross_cu_catch_narrow () =
  let prog =
    let open Hamlet.Combinators in
    let* (module RC) = RemoteCache.Tag.summon () in
    RC.get "key"
  in
  Hamlet.Combinators.catch prog
    ~f:(fun (err : [%hamlet.te RemoteCache]) ->
      match err with
      | #RemoteCache.Errors.rc_miss
      | #RemoteCache.Errors.rc_timeout
      | #RemoteCache.Errors.rc_unavailable
      | #RemoteCache.Errors.rc_corrupt ->
          Hamlet.Combinators.return "handled")

(* xc2 - BAD: handler also declares Console_error; upstream cross-CU
   service emits only the four RemoteCache errors *)
let xc2_cross_cu_catch_widening () =
  let prog =
    let open Hamlet.Combinators in
    let* (module RC) = RemoteCache.Tag.summon () in
    RC.get "key"
  in
  Hamlet.Combinators.catch prog
    ~f:(fun (err : [%hamlet.te RemoteCache, Console]) ->
      match err with
      | #RemoteCache.Errors.rc_miss
      | #RemoteCache.Errors.rc_timeout
      | #RemoteCache.Errors.rc_unavailable
      | #RemoteCache.Errors.rc_corrupt
      | `Console_error _ ->
          Hamlet.Combinators.return "handled")

(* xc3 - GOOD: provide covers exactly RemoteCache's services slot *)
let xc3_cross_cu_provide_narrow () =
  let prog =
    let open Hamlet.Combinators in
    let* (module RC) = RemoteCache.Tag.summon () in
    RC.get "key"
  in
  Hamlet.Combinators.provide prog
    ~handler:(fun (x : [%hamlet.ts RemoteCache]) ->
      match x with
      | #RemoteCache.Tag.r as w ->
          RemoteCache.Tag.give w (failwith "RC"))

(* xc4 - BAD: provide handler declares RemoteCache + Database; upstream
   only summons RemoteCache *)
let xc4_cross_cu_provide_widening () =
  let prog =
    let open Hamlet.Combinators in
    let* (module RC) = RemoteCache.Tag.summon () in
    RC.get "key"
  in
  Hamlet.Combinators.provide prog
    ~handler:(fun (x : [%hamlet.ts RemoteCache, Database]) ->
      match x with
      | #RemoteCache.Tag.r as w ->
          RemoteCache.Tag.give w (failwith "RC")
      | [%hamlet.propagate_s] -> .)
