(** Fixtures for the new combinators whose row annotation sits on a labeled
    handler parameter other than [~f] / the curried second slot of
    [Layer.provide_*]:

    - [Combinators.catch_filter]: row on [~filter] (single-arg)
    - [Combinators.provide_scope]: row on [~handler] curried second slot
      ([Scope_core.t -> 'r_in -> _]) *)

open Hamlet
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
(* Combinators.catch_filter — widening on `'match_` (filter remaps) *)
(* ============================================================ *)

(* cf3 - GOOD: filter remaps `Console_error -> `Renamed; ~f's annotation
   matches what filter actually emits. *)
let cf3_match_remap_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_filter eff
    ~filter:(function `Console_error _ -> Some `Renamed | _ -> None)
    ~f:(fun (_m : [ `Renamed ]) -> return ())
    ~on_no_match:(fun _c -> return ())

(* cf4 - BAD: filter only ever emits `Renamed inside Some, but ~f declares
   `Renamed | `Other. The Other arm is dead. The primary `'e' probe sees
   nothing wrong (filter remaps, `'match_' is independent of `'e'). The new
   filter-output probe should flag this. *)
let cf4_match_remap_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_filter eff
    ~filter:(function `Console_error _ -> Some `Renamed | _ -> None)
    ~f:(fun (_m : [ `Renamed | `Other ]) -> return ())
    ~on_no_match:(fun _c -> return ())

(* cf5 - GOOD: filter has an opaque-option return path (let-bound option used
   as a fallback branch). The walker must abort inference on this shape and
   emit no second-probe finding — emitting one would be a false positive
   because filter genuinely emits `Other via [fallback]. *)
let cf5_filter_opaque_branch_no_finding =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  let fallback = Some `Other in
  catch_filter eff
    ~filter:(function `Console_error _ -> Some `Renamed | _ -> fallback)
    ~f:(fun (_m : [ `Renamed | `Other ]) -> return ())
    ~on_no_match:(fun _c -> return ())

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

(* ps3 - GOOD: provide_scope discharges the implicit [Scope] service plus
   propagates Console. Upstream is let-bound and summons only Console — its
   [val_type] does NOT carry [Scope] because [provide_scope]'s signature is
   generic on ['r_in]. The handler matching [#Scope.Tag.r] is the combinator's
   job, not retroactive widening, so the linter must stay silent.

   Before the [implicit_upstream_tags] classifier extension, this produced a
   false positive: declared = [Scope; Console], upstream = [Console], extra =
   [Scope]. *)
let ps3_provide_scope_implicit_scope_letbound =
  let open Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  provide_scope eff
    ~handler:(fun
        scope (tag : [< `Scope of Scope.Tag.t Hamlet.P.t | Console.Tag.r ]) ->
      match tag with
      | `Scope _ -> Dispatch.give Scope.Tag.key scope
      | #Console.Tag.r as w -> Dispatch.need w)

(* ps4 - GOOD: same shape as ps3 but with inline upstream. The inline
   expression's [exp_type] is unified at the call site against [provide_scope]'s
   ['r_in], so its row already carries [Scope]. Silent both before and after
   the fix; locks in the let-bound vs inline asymmetry of the gap. *)
let ps4_provide_scope_implicit_scope_inline =
  let open Combinators in
  provide_scope
    (let* (module C) = Console.Tag.summon () in
     C.print_endline "go")
    ~handler:(fun
        scope (tag : [< `Scope of Scope.Tag.t Hamlet.P.t | Console.Tag.r ]) ->
      match tag with
      | `Scope _ -> Dispatch.give Scope.Tag.key scope
      | #Console.Tag.r as w -> Dispatch.need w)
