(** Fixtures for combinators whose handler parameter carries the polymorphic-
    variant row inside a {!Hamlet.Cause.t} wrapper.

    The handler declares its error universe via an annotation on the wrapped
    type:
    {[
      ~f:(fun (c : ([%hamlet.te Console, Database]) Hamlet.Cause.t) -> ...)
    ]}

    The linter must strip the [Cause.t] constructor argument to reach the row
    before comparing it against upstream's [val_type] slot.

    Combinators exercised:
    - [Combinators.catch_cause] ([~f], wraps_in_cause = true)
    - [Combinators.catch_cause_filter] ([~filter], wraps_in_cause = true)
    - [Layer.catch_cause] ([~f], wraps_in_cause = true) *)

open Hamlet_test_services

(* ============================================================ *)
(* Combinators.catch_cause                                      *)
(* ============================================================ *)

(* cc1 - GOOD: catch_cause handler covers exactly Console *)
let cc1_catch_cause_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause eff ~f:(fun (c : [%hamlet.te Console] Hamlet.Cause.t) ->
      match Hamlet.Cause.find_fail c with
      | Some (`Console_error _) -> return ()
      | None -> return ())

(* cc2 - BAD: catch_cause handler declares Console + Database; upstream emits only Console *)
let cc2_catch_cause_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause eff ~f:(fun (c : [%hamlet.te Console, Database] Hamlet.Cause.t) ->
      match Hamlet.Cause.find_fail c with
      | Some (`Console_error _ | `Connection_error _ | `Query_error _) ->
          return ()
      | None -> return ())

(* ============================================================ *)
(* Combinators.catch_cause_filter                               *)
(* ============================================================ *)

(* ccf1 - GOOD: catch_cause_filter ~filter parameter declares exactly Console *)
let ccf1_catch_cause_filter_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause_filter eff
    ~filter:(fun (c : [%hamlet.te Console] Hamlet.Cause.t) ->
      Hamlet.Cause.find_fail c)
    ~f:(fun _matched _cause -> return ())
    ~on_no_match:(fun _cause -> return ())

(* ccf2 - BAD: ~filter declares Console + Database; upstream emits only Console *)
let ccf2_catch_cause_filter_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause_filter eff
    ~filter:(fun (c : [%hamlet.te Console, Database] Hamlet.Cause.t) ->
      Hamlet.Cause.find_fail c)
    ~f:(fun _matched _cause -> return ())
    ~on_no_match:(fun _cause -> return ())

(* ccf3 - GOOD: catch_cause_filter with remapping filter; ~f's match_ matches
   what filter actually emits. *)
let ccf3_match_remap_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause_filter eff
    ~filter:(fun c ->
      match Hamlet.Cause.find_fail c with
      | Some (`Console_error _) -> Some `Renamed
      | _ -> None)
    ~f:(fun (_m : [ `Renamed ]) _orig -> return ())
    ~on_no_match:(fun _c -> return ())

(* ccf4 - BAD: same remapping filter; ~f declares `Renamed | `Other while
   filter only emits `Renamed. The filter-output probe must flag this. *)
let ccf4_match_remap_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch_cause_filter eff
    ~filter:(fun c ->
      match Hamlet.Cause.find_fail c with
      | Some (`Console_error _) -> Some `Renamed
      | _ -> None)
    ~f:(fun (_m : [ `Renamed | `Other ]) _orig -> return ())
    ~on_no_match:(fun _c -> return ())

(* ============================================================ *)
(* Layer.catch_cause                                            *)
(* ============================================================ *)

(* lcc1 - GOOD: Layer.catch_cause handler covers exactly Console *)
let lcc1_layer_catch_cause_narrow () =
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.fail (`Console_error "boom"))
  in
  Hamlet.Layer.catch_cause lay
    ~f:(fun (c : [%hamlet.te Console] Hamlet.Cause.t) ->
      let _ = Hamlet.Cause.find_fail c in
      Hamlet.Layer.make Console.Tag.key
        (Hamlet.Combinators.fail (`Console_error "fallback")))

(* lcc2 - BAD: Layer.catch_cause handler declares Console + Database; upstream emits only Console *)
let lcc2_layer_catch_cause_widening () =
  let lay =
    Hamlet.Layer.make Console.Tag.key
      (Hamlet.Combinators.fail (`Console_error "boom"))
  in
  Hamlet.Layer.catch_cause lay
    ~f:(fun (c : [%hamlet.te Console, Database] Hamlet.Cause.t) ->
      let _ = Hamlet.Cause.find_fail c in
      Hamlet.Layer.make Console.Tag.key
        (Hamlet.Combinators.fail (`Console_error "fallback")))
