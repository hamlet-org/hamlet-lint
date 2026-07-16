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
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Timeout -> ()
  | Error `Recovery -> Alcotest.fail "residual error used the handled callback"
  | Ok () -> Alcotest.fail "residual error disappeared"

let generic_helper_specializes_again () =
  let source : (unit, [ `Missing | `Offline ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Offline
  in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.recover_missing source
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Offline -> ()
  | Error `Recovery -> Alcotest.fail "second specialization changed residual"
  | Ok () -> Alcotest.fail "second specialization lost its residual"

let generic_call_inside_catch () =
  let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Missing
  in
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())
  |> Hamlet.Interpreter.run
  |> Alcotest.(check (result unit reject)) "generic call inside catch" (Ok ())

let generic_call_inside_chain () =
  let source : (string, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.return "ready"
  in
  Hamlet.Combinators.chain
    (Hamlet_subtractor_generic_helper_producer.recover_missing source)
    ~handler:(fun value -> Hamlet.Combinators.return (value ^ "!"))
  |> Hamlet.Combinators.catch ~handler:(function
    | `Recovery -> Hamlet.Combinators.return "recovery"
    | `Timeout -> Hamlet.Combinators.return "timeout")
  |> expect_ok "generic call inside chain" "ready!"

let generic_output_to_error_marker () =
  let module Errors = struct
    type missing = [ `Missing ]
    type timeout = [ `Timeout ]
    type recovery = [ `Recovery ]
    type source = [ missing | timeout ]
  end in
  let run error =
    let source : (string, Errors.source, Hamlet.never) Hamlet.t =
      Hamlet.Combinators.fail error
    in
    Hamlet.Combinators.catch
      (Hamlet_subtractor_generic_helper_producer.recover_missing source)
      ~handler:(function
      | #Errors.recovery -> Hamlet.Combinators.return "recovered"
      | [%hamlet.propagate_e.auto] -> .)
    |> Hamlet.Combinators.catch ~handler:(function #Errors.timeout ->
        Hamlet.Combinators.return "timeout")
  in
  run `Missing
  |> expect_ok "generic output marker handles helper error" "recovered";
  run `Timeout
  |> expect_ok "generic output marker forwards source error" "timeout"

let generic_output_feeds_following_marker () =
  let module Errors = struct
    type missing = [ `Missing ]
    type offline = [ `Offline ]
    type timeout = [ `Timeout ]
    type source = [ missing | offline | timeout ]
  end in
  let run error =
    let source : (unit, Errors.source, Hamlet.never) Hamlet.t =
      Hamlet.Combinators.fail error
    in
    let after =
      Hamlet.Combinators.catch
        (Hamlet_subtractor_generic_helper_producer.recover_missing_to_unit
           source) ~handler:(function
        | #Errors.offline -> Hamlet.Combinators.return ()
        | [%hamlet.propagate_e.auto] -> .)
    in
    Hamlet.Combinators.catch after ~handler:(function #Errors.timeout ->
        Hamlet.Combinators.return ())
    |> Hamlet.Interpreter.run
  in
  Alcotest.(check (result unit reject))
    "the helper handles Missing" (Ok ()) (run `Missing);
  Alcotest.(check (result unit reject))
    "the following marker handles Offline" (Ok ()) (run `Offline);
  Alcotest.(check (result unit reject))
    "the marker forwards Timeout" (Ok ()) (run `Timeout)

let generic_catch_cause_clears_source_errors () =
  let run replacement =
    let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
      Hamlet.Combinators.fail `Missing
    in
    Hamlet_subtractor_generic_helper_producer.recover_cause replacement source
    |> Hamlet.Interpreter.run
  in
  Alcotest.(check (result unit reject))
    "the later marker handles the visible cause recovery" (Ok ()) (run true);
  match run false with
  | Error `Cause_residual -> ()
  | Ok () -> Alcotest.fail "the visible cause handler error disappeared"

let ordinary_qualified_calls_are_unchanged () =
  Alcotest.(check int)
    "ordinary qualified application" 42
    (Hamlet_subtractor_generic_helper_producer.Ordinary.identity
       (Hamlet_subtractor_generic_helper_producer.Ordinary.add 19 23))

let generic_helper_infers_concrete_source () =
  let source = Hamlet.Combinators.fail `Missing in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.recover_missing source
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Recovery -> ()
  | Ok () -> Alcotest.fail "inferred source error disappeared"

let nested_generic_helper_handles_inner_error () =
  let source : (unit, [ `Extra | `Missing | `Other ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Missing
  in
  let specialized =
    Hamlet_subtractor_nested_outer_fixture.recover_other source
  in
  Alcotest.(check (result unit reject))
    "inner helper handles Missing" (Ok ())
    (Hamlet.Interpreter.run specialized)

let nested_generic_helper_handles_outer_error () =
  let source : (unit, [ `Extra | `Missing | `Other ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Other
  in
  let specialized =
    Hamlet_subtractor_nested_outer_fixture.recover_other source
  in
  Alcotest.(check (result unit reject))
    "outer helper handles Other" (Ok ())
    (Hamlet.Interpreter.run specialized)

let nested_generic_helper_forwards_residual_error () =
  let source : (unit, [ `Extra | `Missing | `Other ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Extra
  in
  let specialized =
    Hamlet_subtractor_nested_outer_fixture.recover_other source
  in
  match Hamlet.Interpreter.run specialized with
  | Error `Extra -> ()
  | Ok () -> Alcotest.fail "residual error disappeared"

let two_nested_generic_helpers_handle_both_errors () =
  let missing : (unit, [ `Extra | `Missing | `Other ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Missing
  in
  let other : (unit, [ `Extra | `Missing | `Other ], Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail `Other
  in
  Alcotest.(check (result unit reject))
    "first nested helper" (Ok ())
    (Hamlet.Interpreter.run
       (Hamlet_subtractor_nested_outer_fixture.recover_both missing));
  Alcotest.(check (result unit reject))
    "second nested helper" (Ok ())
    (Hamlet.Interpreter.run
       (Hamlet_subtractor_nested_outer_fixture.recover_both other))

module Generic_logger_live =
Hamlet_subtractor_generic_helper_producer.Logger.Make (struct
  let log _ = Hamlet.Combinators.return ()
end)

module Generic_clock_live =
Hamlet_subtractor_generic_helper_producer.Clock.Make (struct
  let now () = Hamlet.Combinators.return 42
end)

let generic_helper_provides_requirement () =
  let source =
    let open Hamlet.Combinators in
    let* _logger =
      Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon
    in
    return ()
  in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.provide_logger
      (module Generic_logger_live)
      source
  in
  Alcotest.(check (result unit reject))
    "generic helper provides Logger" (Ok ())
    (Hamlet.Interpreter.run specialized)

let generic_helper_forwards_residual_requirement () =
  let source =
    let open Hamlet.Combinators in
    let* _logger =
      Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon
    in
    let* _clock = Hamlet_subtractor_generic_helper_producer.Clock.Tag.summon in
    return ()
  in
  let specialized =
    Hamlet_subtractor_generic_helper_producer.provide_logger
      (module Generic_logger_live)
      source
  in
  specialized
  |> Combinators.provide ~handler:(function
      | #Hamlet_subtractor_generic_helper_producer.Clock.Tag.r as witness ->
      Hamlet_subtractor_generic_helper_producer.Clock.Tag.give witness
        (module Generic_clock_live))
  |> Hamlet.Interpreter.run
  |> Alcotest.(check (result unit reject))
       "generic helper forwards Clock" (Ok ())

let generic_output_to_requirement_marker () =
  let source =
    let open Hamlet.Combinators in
    let* _logger =
      Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon
    in
    let* _clock = Hamlet_subtractor_generic_helper_producer.Clock.Tag.summon in
    return ()
  in
  Hamlet.Combinators.provide
    (Hamlet_subtractor_generic_helper_producer.provide_logger
       (module Generic_logger_live)
       source)
    ~handler:((function
      | #Hamlet_subtractor_generic_helper_producer.Clock.Tag.r as witness ->
          Hamlet_subtractor_generic_helper_producer.Clock.Tag.give witness
            (module Generic_clock_live)
      | [%hamlet.propagate_s.auto] -> .) [@warning "-11"])
  |> Hamlet.Interpreter.run
  |> Alcotest.(check (result unit reject))
       "generic output marker provides residual Clock" (Ok ())

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
          Alcotest.test_case "generic helper specializes again" `Quick
            generic_helper_specializes_again;
          Alcotest.test_case "generic call inside catch" `Quick
            generic_call_inside_catch;
          Alcotest.test_case "generic call inside chain" `Quick
            generic_call_inside_chain;
          Alcotest.test_case "generic output feeds an error marker" `Quick
            generic_output_to_error_marker;
          Alcotest.test_case "generic output feeds a following marker" `Quick
            generic_output_feeds_following_marker;
          Alcotest.test_case "generic catch_cause replaces source errors" `Quick
            generic_catch_cause_clears_source_errors;
          Alcotest.test_case "ordinary qualified calls remain ordinary" `Quick
            ordinary_qualified_calls_are_unchanged;
          Alcotest.test_case "generic helper infers concrete source" `Quick
            generic_helper_infers_concrete_source;
          Alcotest.test_case "nested helper handles inner error" `Quick
            nested_generic_helper_handles_inner_error;
          Alcotest.test_case "nested helper handles outer error" `Quick
            nested_generic_helper_handles_outer_error;
          Alcotest.test_case "nested helper forwards residual error" `Quick
            nested_generic_helper_forwards_residual_error;
          Alcotest.test_case "two nested generic helpers" `Quick
            two_nested_generic_helpers_handle_both_errors;
        ] );
      ( "requirements",
        [
          Alcotest.test_case "give and generated need" `Quick
            requirements_give_and_forward;
          Alcotest.test_case "explicit need" `Quick explicit_need_is_preserved;
          Alcotest.test_case "guarded requirement" `Quick
            guarded_requirement_is_forwarded;
          Alcotest.test_case "generic helper provides requirement" `Quick
            generic_helper_provides_requirement;
          Alcotest.test_case "generic helper forwards residual requirement"
            `Quick generic_helper_forwards_residual_requirement;
          Alcotest.test_case "generic output feeds a requirement marker" `Quick
            generic_output_to_requirement_marker;
        ] );
    ]
