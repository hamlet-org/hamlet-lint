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
      (string, Automatic_propagation_external.Storage.Errors.error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_timeout "slow" : Automatic_propagation_external.Storage.Errors.error)
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
      (string, Automatic_propagation_external.Storage.Errors.error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_missing "gone" : Automatic_propagation_external.Storage.Errors.error)
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
          Automatic_propagation_external.Logger.Tag.give witness (module Logger_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness (module Clock_live))
  |> expect_ok "give and generated need" "ready"

let explicit_need_is_preserved () =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      (match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Hamlet.Dispatch.need witness
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness (module Clock_live)
      | [%hamlet.propagate_s.auto] -> .)
      [@warning "-11"])
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness (module Logger_live))
  |> expect_ok "explicit need" "ready"

let guarded_requirement_is_forwarded () =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness when false ->
          Automatic_propagation_external.Logger.Tag.give witness (module Logger_live)
      | #Automatic_propagation_external.Clock.Tag.r as witness ->
          Automatic_propagation_external.Clock.Tag.give witness (module Clock_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness (module Logger_live))
  |> expect_ok "guarded requirement" "ready"

let provision_error_crosses_provide () =
  Automatic_propagation_external.provision_program
  |> Combinators.provide ~handler:(fun requirement ->
      (match requirement with
      | #Automatic_propagation_external.Provision.Tag.r as witness ->
          Automatic_propagation_external.Provision.Tag.give witness (module Provision_live)
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
      (string, Automatic_propagation_external.Storage.Errors.error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail
      (`Storage_corrupt "bad" : Automatic_propagation_external.Storage.Errors.error)
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
          Alcotest.test_case "provision error crosses provide" `Quick
            provision_error_crosses_provide;
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
