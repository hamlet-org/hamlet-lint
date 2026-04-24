(** Fixtures for the recursive-residual feature: chained inline catch / provide
    / Layer.provide_* without intermediate let-bindings.

    Without recursion the linter would fall back to upstream's widened
    [exp_type] (already pinned to the outer handler's universe) and miss every
    retroactive widening on the outer step. With recursion, each pure-propagate
    / pure-discharge inner combinator becomes a row no-op (or a known
    set-arithmetic step) and the outer step's residual is computed accurately.
*)

open Hamlet_test_services

(* ============================================================ *)
(* CATCH chains — Combinators.catch                             *)
(* ============================================================ *)

(* c1 - GOOD: two catches in pipe form, both narrow to upstream's actual
   emissions. No widening at any step. Expect no warning. *)
let c1_chained_catch_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  eff
  |> catch ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)
  |> catch ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)

(* c2 - BAD: two catches in pipe form. Inner is pure-propagate (residual =
   upstream actual = [Console_error]). Outer declares Console + Database.
   With recursive residual the outer must be flagged on this line. *)
let c2_chained_catch_outer_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  eff
  |> catch ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)
  |> catch ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* c3 - BAD: nested form (not pipe), inner catch wrapped inside outer's
   positional arg directly. Same shape as the LIMITATIONS §1.1 outer
   example before this PR. Recursive residual catches it now. *)
let c3_nested_catch_outer_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch
    (catch eff ~f:(fun (x : [%hamlet.te Console]) ->
         match x with [%hamlet.propagate_e] -> .))
    ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* c4 - BAD: triple-chain in pipe form. Innermost narrow, middle still
   narrow, outer widens. Outer must be flagged; the two inner catches
   must be silent (no widening). *)
let c4_triple_catch_outer_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  eff
  |> catch ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)
  |> catch ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)
  |> catch ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* ============================================================ *)
(* PROVIDE chains — Combinators.provide                         *)
(* ============================================================ *)

(* p1 - GOOD: two provides, inner gives Console + propagates Database
   (mixed give+need → residual_r drops Console, keeps Database), outer
   gives exactly the remaining service. *)
let p1_chained_provide_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  provide
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
         | [%hamlet.propagate_s] -> .))
    ~h:(fun (x : [%hamlet.ts Database]) ->
      match x with #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

(* p2 - BAD: outer provide declares Console + Database but the inner
   provide already discharged Console; residual_r is Database only. The
   outer's Console is "extra not emitted by upstream", flag the outer. *)
let p2_chained_provide_outer_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  provide
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
         | [%hamlet.propagate_s] -> .))
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

(* ============================================================ *)
(* CROSS — outer catch over inner provide (slot 1 pass-through) *)
(* ============================================================ *)

(* x1 - BAD: outer catch's true upstream errors row is unchanged across
   inner provide (provide does not touch errors). Inner upstream emits
   only Console_error. Outer declares Console + Database errors. Flag. *)
let x1_catch_over_provide_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* () = C.print_endline "go" in
    return ()
  in
  catch
    (provide eff ~h:(fun (x : [%hamlet.ts Console]) ->
         match x with #Console.Tag.r as w -> Console.Tag.give w (failwith "C")))
    ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* x2 - GOOD: outer provide over inner catch. Catch is slot-2
   pass-through, so residual_r is upstream's actual services. Outer
   provide declares exactly that. *)
let x2_provide_over_catch_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  provide
    (catch eff ~f:(fun (x : [%hamlet.te Console]) ->
         match x with [%hamlet.propagate_e] -> .))
    ~h:(fun (x : [%hamlet.ts Console]) ->
      match x with #Console.Tag.r as w -> Console.Tag.give w (failwith "C"))

(* ============================================================ *)
(* LAYER chains — Layer.provide_to_effect (curried handler)     *)
(* ============================================================ *)

(* lpe1 - BAD: outer Layer.provide_to_effect chained inline over an
   inner Combinators.provide. Inner gives Console (residual_r =
   upstream_r ∖ Console = Database). Outer's curried handler declares
   Console + Database — Console is extra. Flag the outer. *)
let lpe1_chained_layer_provide_outer_widening () =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  let lay =
    Hamlet.Layer.make Database.Tag.key
      (Hamlet.Combinators.return (failwith "D"))
  in
  Hamlet.Layer.provide_to_effect ~s:lay
    ~h:(fun impl (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w impl)
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
         | [%hamlet.propagate_s] -> .))

(* lpe2 - GOOD: same shape as lpe1 but the outer's handler declares
   exactly the residual (Database only, since inner already discharged
   Console and only re-needed Database). *)
(* fp1 - GOOD (regression): user-defined helpers named [give] / [expose_*]
   in an inline inner combinator must NOT make the residual look narrower
   than it really is. Without provenance gates on the give/expose
   detectors a bogus outer finding would appear here. *)
module User_helpers_for_fp_test = struct
  let give w _ =
    Hamlet.Dispatch.need w (* same shape as Tag.give but user-defined *)
  let expose_x e = e (* user-defined non-hamlet expose *)
  let _ = expose_x (* suppress unused warning *)
end

let fp1_user_give_no_false_positive =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  (* outer provide declares Console+Database. Inner provide uses a
     USER-DEFINED [give] (re-needs the tag instead of discharging). The
     residual on slot 2 = upstream slot 2 = [Console; Database]. Since
     outer == upstream, no finding. With the old over-permissive
     give detector, the user-defined [give] would have been classified
     as a discharge → residual narrowed → bogus outer finding. *)
  provide
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> User_helpers_for_fp_test.give w (failwith "C")
         | #Database.Tag.r as w ->
             User_helpers_for_fp_test.give w (failwith "D")))
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

(* fp2 - GOOD (regression): a user-defined [Tag.give] (parent module
   literally called "Tag" but the give is hand-written and re-needs
   instead of discharging). The first-arg-is-Tconstr-r gate catches
   this: the user's give has no [r] annotation, so its val_type's first
   arg is a generic [Tvar], not a [Tconstr] to [<...>.r]. *)
module User_helpers_with_tag_module = struct
  module Tag = struct
    let give w _ = Hamlet.Dispatch.need w
  end
end

let fp2_user_tag_module_no_false_positive =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  provide
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w ->
             User_helpers_with_tag_module.Tag.give w (failwith "C")
         | #Database.Tag.r as w ->
             User_helpers_with_tag_module.Tag.give w (failwith "D")))
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

(* fn1 - BAD (regression): module-aliased Tag.give must STILL be
   detected as discharge so chained inline provide flagging keeps
   working. The gate intentionally avoids checking the parent module's
   name (which would be [CT]/[DT], not [Tag], in this scenario) and
   relies on val_type structure instead. *)
module CT = Console.Tag
module DT = Database.Tag

let fn1_module_alias_tag_give_still_flagged =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  provide
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> CT.give w (failwith "C")
         | #Database.Tag.r as w -> DT.give w (failwith "D")))
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      (* outer declares Console+Database but residual after inner =
         empty (inner discharged both). Flag. *)
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

let lpe2_chained_layer_provide_narrow () =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  let lay =
    Hamlet.Layer.make Database.Tag.key
      (Hamlet.Combinators.return (failwith "D"))
  in
  Hamlet.Layer.provide_to_effect ~s:lay
    ~h:(fun impl (x : [%hamlet.ts Database]) ->
      match x with #Database.Tag.r as w -> Database.Tag.give w impl)
    (provide eff ~h:(fun (x : [%hamlet.ts Console, Database]) ->
         match x with
         | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
         | [%hamlet.propagate_s] -> .))
