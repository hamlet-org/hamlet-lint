(** Fixtures for the post-compile widening linter PoC.
    Each function demonstrates a catch/provide case the linter should flag or pass. *)

open Hamlet_test_services

(* ========== CATCH cases ========== *)

(* case 1 — GOOD: upstream emits only Console errors; handler declares only Console *)
let good_catch_narrow =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:(fun (x : [%hamlet.te Console]) ->
      match x with [%hamlet.propagate_e] -> .)

(* case 2 — BAD: upstream emits only Console; handler declares Console + Database *)
let bad_catch_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  catch eff ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* case 3 — GOOD: upstream emits Console + Database; handler covers both *)
let good_catch_full =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  catch eff ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)

(* ========== PROVIDE cases ========== *)

(* case 4 — GOOD: summons Console + Database; provide declares both *)
let good_provide =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    let* (module D) = Database.Tag.summon () in
    let* () = C.print_endline "go" in
    D.connect "x"
  in
  provide eff
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | #Database.Tag.r as w -> Database.Tag.give w (failwith "D"))

(* case 5 — BAD: summons only Console; provide declares Console + Database *)
let bad_provide_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"
  in
  provide eff
    ~h:(fun (x : [%hamlet.ts Console, Database]) ->
      match x with
      | #Console.Tag.r as w -> Console.Tag.give w (failwith "C")
      | [%hamlet.propagate_s] -> .)
