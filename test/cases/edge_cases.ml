(** Edge cases: inline upstream, chained catches, multi-handler. *)
open Hamlet_test_services

(* E1 - GOOD: inline upstream (no let-binding), handler narrow. Expect no warn. *)
let e1_inline_good =
  let open Hamlet.Combinators in
  catch
    (let* (module C) = Console.Tag.summon () in C.print_endline "go")
    ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)

(* E2 - BAD: inline upstream, widening handler. Without val_type we fall back
   to exp_type which is already widened. Linter may give false negative here. *)
let e2_inline_bad =
  let open Hamlet.Combinators in
  catch
    (let* (module C) = Console.Tag.summon () in C.print_endline "go")
    ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* E3 - GOOD: chained catches, each narrow. *)
let e3_chained_good =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  let after_first =
    catch eff ~f:(fun (x : [%hamlet.te Console]) ->
        match x with [%hamlet.propagate_e] -> .)
  in
  catch after_first ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)

(* E4 - BAD: second catch widens *)
let e4_chained_bad =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  let after_first =
    catch eff ~f:(fun (x : [%hamlet.te Console]) ->
        match x with [%hamlet.propagate_e] -> .)
  in
  catch after_first ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* E5 - OPEN row handler without [%hamlet.te]: out of scope but should not crash. *)
let e5_open_handler =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:(fun (x : [> `Console_error of string ]) ->
      match x with `Console_error _ -> failure `Fallback)

(* E6 - GOOD: non-Hamlet catch-like name (unrelated fn) should not be flagged *)
let my_catch _up ~f:_h = ()

(* E7 - BAD: whole-function annotation form: catch with (function ... : [%hamlet.te ...] -> _) *)
let e7_whole_fn_bad =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:((function [%hamlet.propagate_e] -> .) : [%hamlet.te Console, Database] -> _)

(* E8 - BAD: scrutinee annotation form: fun x -> match (x : [%hamlet.te ...]) with ... *)
let e8_scrutinee_bad =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:(fun x ->
      match (x : [%hamlet.te Console, Database]) with
      | [%hamlet.propagate_e] -> .)

(* E9 - BAD: module alias. Should be caught via Path.name resolution. *)
let e9_alias_bad =
  let module HC = Hamlet.Combinators in
  let eff =
    let open HC in
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  HC.catch eff ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* E10 - BAD: handler defined as a top-level fn, passed by name. *)
let handle_wide_te (x : [%hamlet.te Console, Database]) =
  match x with [%hamlet.propagate_e] -> .

let e10_named_handler_bad =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:handle_wide_te
