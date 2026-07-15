open Hamlet

module Logger_live = Automatic_propagation_external.Logger.Make (struct
  let log _ = Hamlet.Combinators.return ()
end)

module Clock_live = Automatic_propagation_external.Clock.Make (struct
  let now () = Hamlet.Combinators.return 42
end)

module Provision_live = Automatic_propagation_external.Provision.Make (struct
  let fetch () = Hamlet.Combinators.fail (`Provision_error "failed")
end)

let expect_ok name expected eff =
  Alcotest.(check (result string reject))
    name (Ok expected)
    (Hamlet.Interpreter.run eff)

let cross_cu_error_propagates () =
  let source :
      ( string,
        Automatic_propagation_external.Storage.Errors.error,
        Hamlet.never )
      Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_timeout "slow"
        : Automatic_propagation_external.Storage.Errors.error)
  in
  source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function
    | `Storage_timeout _ -> Hamlet.Combinators.return "timeout"
    | `Storage_unavailable _ -> Hamlet.Combinators.return "unavailable"
    | `Storage_corrupt _ -> Hamlet.Combinators.return "corrupt")
  |> expect_ok "cross CU error propagation" "timeout"

let recovery_error_is_preserved () =
  let source :
      ( string,
        Automatic_propagation_external.Storage.Errors.error,
        Hamlet.never )
      Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_missing "gone"
        : Automatic_propagation_external.Storage.Errors.error)
  in
  source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          Hamlet.Combinators.fail `Recovery_error
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function
    | `Recovery_error -> Hamlet.Combinators.return "recovery"
    | `Storage_timeout _ -> Hamlet.Combinators.return "timeout"
    | `Storage_unavailable _ -> Hamlet.Combinators.return "unavailable"
    | `Storage_corrupt _ -> Hamlet.Combinators.return "corrupt")
  |> expect_ok "recovery error" "recovery"

let requirements_give_and_forward () =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module Logger_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness
            (module Clock_live))
  |> expect_ok "give and generated need" "ready"

let explicit_need_is_preserved () =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      (match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Hamlet.Dispatch.need witness
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness
            (module Clock_live)
      | [%hamlet.propagate_s.auto] -> .)
      [@warning "-11"])
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module Logger_live))
  |> expect_ok "explicit need" "ready"

let guarded_requirement_is_forwarded () =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness when false ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module Logger_live)
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness
            (module Clock_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module Logger_live))
  |> expect_ok "guarded requirement" "ready"

let provision_error_crosses_provide () =
  Automatic_propagation_external.provision_program
  |> Combinators.provide ~handler:(fun requirement ->
      (match requirement with
      | #Automatic_propagation_external.Provision.Tag.r as witness ->
          Automatic_propagation_external.Provision.Tag.give witness
            (module Provision_live)
      | [%hamlet.propagate_s.auto] -> .)
      [@warning "-11"])
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Provision.Errors.provision_fallback ->
          Hamlet.Combinators.return "fallback"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function `Provision_error _ ->
      Hamlet.Combinators.return "provision-error")
  |> expect_ok "provision error" "provision-error"

let dependent_error_markers () =
  let source :
      ( string,
        Automatic_propagation_external.Storage.Errors.error,
        Hamlet.never )
      Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_corrupt "bad"
        : Automatic_propagation_external.Storage.Errors.error)
  in
  source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_timeout ->
          Hamlet.Combinators.return "timeout"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function
    | `Storage_unavailable _ -> Hamlet.Combinators.return "unavailable"
    | `Storage_corrupt _ -> Hamlet.Combinators.return "corrupt")
  |> expect_ok "dependent error markers" "corrupt"

module Alternating_errors = struct
  type a = [ `Alternating_a ]
  type b = [ `Alternating_b ]
  type c = [ `Alternating_c ]
  type source = [ a | b | c ]
  type replacement_a = [ `Replacement_a ]
end

let alternating_chain_and_catch choose_c =
  let source : (string, Alternating_errors.source, Hamlet.never) Hamlet.t =
    if choose_c then Combinators.fail `Alternating_c
    else Combinators.fail `Alternating_b
  in
  source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Alternating_errors.a -> Combinators.return "a"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.chain ~handler:(fun value -> Combinators.return value)
  |> Combinators.catch ~handler:(function
    | `Alternating_b -> Combinators.fail `Replacement_a
    | `Alternating_c -> Combinators.fail `Replacement_b)
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Alternating_errors.replacement_a -> Combinators.return "replacement-a"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function `Replacement_b ->
      Combinators.return "replacement-b")

let chain_then_catch_handles_first_replacement () =
  alternating_chain_and_catch false
  |> expect_ok "chain then catch first branch" "replacement-a"

let chain_then_catch_forwards_second_replacement () =
  alternating_chain_and_catch true
  |> expect_ok "chain then catch second branch" "replacement-b"

let catch_filter_between_markers () =
  let source : (string, Alternating_errors.source, Hamlet.never) Hamlet.t =
    Combinators.fail `Alternating_b
  in
  source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Alternating_errors.a -> Combinators.return "a"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch_filter
       ~filter:(function `Alternating_b -> Some () | `Alternating_c -> None)
       ~handler:(fun () -> Combinators.fail `Replacement_a)
       ~on_no_match:(fun _cause -> Combinators.fail `Replacement_b)
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Alternating_errors.replacement_a -> Combinators.return "matched"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function `Replacement_b ->
      Combinators.return "not-matched")
  |> expect_ok "catch filter between markers" "matched"

module Chain_errors = struct
  type old_a = [ `Chain_old_a ]
  type old_b = [ `Chain_old_b ]
  type old_c = [ `Chain_old_c ]
  type old = [ old_a | old_b | old_c ]
  type introduced_one = [ `Chain_introduced_one ]
  type introduced_two = [ `Chain_introduced_two ]
  type after_first = [ old_b | old_c | introduced_one ]
  type after_second = [ old_c | introduced_one | introduced_two ]
end

let chained_error_markers use_second =
  let source : (string, Chain_errors.old, Hamlet.never) Hamlet.t =
    if use_second then Hamlet.Combinators.fail (`Chain_old_b : Chain_errors.old)
    else Hamlet.Combinators.fail (`Chain_old_a : Chain_errors.old)
  in
  let first =
    source
    |> Combinators.catch ~handler:(fun error ->
        match error with
        | #Chain_errors.old_a -> Hamlet.Combinators.return "old-a"
        | [%hamlet.propagate_e.auto] -> .)
  in
  let with_introduced_one =
    let first =
      (first :> (string, Chain_errors.after_first, Hamlet.never) Hamlet.t)
    in
    let open Hamlet.Combinators in
    let* _ = first in
    (fail (`Chain_introduced_one : Chain_errors.introduced_one)
      :> (string, Chain_errors.after_first, Hamlet.never) Hamlet.t)
  in
  with_introduced_one
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Chain_errors.old_b ->
          (Hamlet.Combinators.fail
             (`Chain_introduced_two : Chain_errors.introduced_two)
            :> (string, Chain_errors.after_second, Hamlet.never) Hamlet.t)
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Chain_errors.introduced_one ->
          Hamlet.Combinators.return "introduced-one"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(function
    | `Chain_old_c -> Hamlet.Combinators.return "old-c"
    | `Chain_introduced_two -> Hamlet.Combinators.return "introduced-two")

let chain_handles_effect_added_by_let () =
  chained_error_markers false
  |> expect_ok "chain handles let effect" "introduced-one"

let chain_handles_recovery_added_later () =
  chained_error_markers true
  |> expect_ok "chain handles recovery effect" "introduced-two"

let generic_helper_handles_claimed_error () =
  let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Missing
  in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.recover_missing source
      [%hamlet.forward.auto]
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Recovery -> ()
  | Error `Timeout -> Alcotest.fail "claimed error was forwarded"
  | Ok () -> Alcotest.fail "claimed error disappeared"

let generic_helper_forwards_residual_error () =
  let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Timeout
  in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.recover_missing source
      [%hamlet.forward.auto]
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Timeout -> ()
  | Error `Recovery -> Alcotest.fail "residual error used the handled callback"
  | Ok () -> Alcotest.fail "residual error disappeared"

let () =
  Alcotest.run "automatic propagation"
    [
      ( "errors",
        [
          Alcotest.test_case "cross CU propagation" `Quick
            cross_cu_error_propagates;
          Alcotest.test_case "recovery adds error" `Quick
            recovery_error_is_preserved;
          Alcotest.test_case "dependent markers" `Quick dependent_error_markers;
          Alcotest.test_case "chain then catch handles replacement" `Quick
            chain_then_catch_handles_first_replacement;
          Alcotest.test_case "chain then catch forwards replacement" `Quick
            chain_then_catch_forwards_second_replacement;
          Alcotest.test_case "catch filter between markers" `Quick
            catch_filter_between_markers;
          Alcotest.test_case "chain adds an error" `Quick
            chain_handles_effect_added_by_let;
          Alcotest.test_case "recovery adds a later error" `Quick
            chain_handles_recovery_added_later;
          Alcotest.test_case "provision error crosses provide" `Quick
            provision_error_crosses_provide;
          Alcotest.test_case "generic helper handles claimed error" `Quick
            generic_helper_handles_claimed_error;
          Alcotest.test_case "generic helper forwards residual error" `Quick
            generic_helper_forwards_residual_error;
        ] );
      ( "requirements",
        [
          Alcotest.test_case "give and generated need" `Quick
            requirements_give_and_forward;
          Alcotest.test_case "explicit need" `Quick explicit_need_is_preserved;
          Alcotest.test_case "guarded requirement" `Quick
            guarded_requirement_is_forwarded;
        ] );
    ]
