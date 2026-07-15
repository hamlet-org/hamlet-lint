open Hamlet

[%%hamlet.service
module type Local_io = sig
  type local_missing = [ `Local_missing of string ]
  type local_corrupt = [ `Local_corrupt of string ]
  type local_denied = [ `Local_denied ]

  val load :
    string -> (string, [> local_missing | local_corrupt | local_denied ], 'r) t
end]

[%%hamlet.service
module type Local_logger = sig
  val log : string -> (unit, [> ], 'r) t
end]

[%%hamlet.service
module type Local_clock = sig
  val now : unit -> (int, [> ], 'r) t
end]

[%%hamlet.service
module type Local_audit = sig
  val record : string -> (unit, [> ], 'r) t
end]

[%%hamlet.service
module type Local_metrics = sig
  val increment : string -> (unit, [> ], 'r) t
end]

module Local_logger_live = Local_logger.Make (struct
  let log _ = Hamlet.Combinators.return ()
end)

module Local_clock_live = Local_clock.Make (struct
  let now () = Hamlet.Combinators.return 0
end)

module Local_audit_live = Local_audit.Make (struct
  let record _ = Hamlet.Combinators.return ()
end)

module Local_metrics_live = Local_metrics.Make (struct
  let increment _ = Hamlet.Combinators.return ()
end)

module Provision_live = Automatic_propagation_external.Provision.Make (struct
  let fetch () = Hamlet.Combinators.fail (`Provision_error "failed")
end)

module Exact_errors = struct
  type a = [ `Exact_a ]
  type b = [ `Exact_b of string ]
  type error = [ a | b ]
end

module Mixed_errors = struct
  type a = [ `Mixed_a ]
  type b = [ `Mixed_b of string ]
  type error = [ a | b ]
end

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

let local_error_source :
    (string, Local_io.Errors.error, Local_io.Tag.r) Hamlet.t =
  Hamlet.Combinators.fail (`Local_corrupt "bad" : Local_io.Errors.error)

let local_requirement_source :
    ( string,
      Hamlet.never,
      [ Local_logger.Tag.r | Local_clock.Tag.r | Local_audit.Tag.r ] )
    Hamlet.t =
  Hamlet.Combinators.return "ready"

let exact_error_source : (string, Exact_errors.error, never) t =
  Hamlet.Combinators.fail (`Exact_a : Exact_errors.error)

let recovery_requirement_source =
  Hamlet.Combinators.fail (`Exact_a : Exact_errors.error)

type storage_subset =
  [ Automatic_propagation_external.Storage.Errors.storage_missing
  | Automatic_propagation_external.Storage.Errors.storage_timeout ]

let storage_subset_source : (string, storage_subset, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`Storage_timeout "slow" : storage_subset)

let mixed_source :
    (string, Mixed_errors.error, [ Local_logger.Tag.r | Local_clock.Tag.r ]) t =
  Hamlet.Combinators.fail (`Mixed_a : Mixed_errors.error)

let chain_source : (string, Chain_errors.old, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`Chain_old_a : Chain_errors.old)

let case_error_local_direct =
  Combinators.catch local_error_source ~handler:(fun error ->
      match error with
      | #Local_io.Errors.local_missing -> Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)

let case_error_cross_pipe =
  Automatic_propagation_external.storage_program
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)

let case_error_cross_subset =
  Combinators.catch storage_subset_source ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)

let case_error_recovery_adds =
  Combinators.catch local_error_source ~handler:(fun error ->
      match error with
      | #Local_io.Errors.local_missing ->
          Hamlet.Combinators.fail `Recovery_error
      | [%hamlet.propagate_e.auto] -> .)

let case_error_guarded =
  Combinators.catch local_error_source ~handler:(fun error ->
      match error with
      | #Local_io.Errors.local_missing when false ->
          Hamlet.Combinators.return "guarded"
      | #Local_io.Errors.local_corrupt -> Hamlet.Combinators.return "corrupt"
      | [%hamlet.propagate_e.auto] -> .)

let case_error_exhausted =
  Combinators.catch exact_error_source ~handler:(fun error ->
      (match error with
      | #Exact_errors.a -> Hamlet.Combinators.return "a"
      | #Exact_errors.b -> Hamlet.Combinators.return "b"
      | [%hamlet.propagate_e.auto] -> .)
      [@warning "-11"])

let case_error_function =
  Combinators.catch local_error_source ~handler:(function
    | #Local_io.Errors.local_denied -> Hamlet.Combinators.return "denied"
    | [%hamlet.propagate_e.auto] -> .)

let case_error_dependent =
  local_error_source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Local_io.Errors.local_missing -> Hamlet.Combinators.return "missing"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Local_io.Errors.local_corrupt -> Hamlet.Combinators.return "corrupt"
      | [%hamlet.propagate_e.auto] -> .)

let case_error_chain_composition =
  let first =
    chain_source
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
      | #Chain_errors.introduced_one -> Hamlet.Combinators.return "introduced"
      | [%hamlet.propagate_e.auto] -> .)

let case_requirement_local_direct =
  Combinators.provide
    ~handler:(fun requirement ->
      match requirement with
      | #Local_logger.Tag.r as witness ->
          Local_logger.Tag.give witness (module Local_logger_live)
      | [%hamlet.propagate_s.auto] -> .)
    local_requirement_source

let case_requirement_need =
  Combinators.provide
    ~handler:(fun requirement ->
      match requirement with
      | #Local_logger.Tag.r as witness -> Hamlet.Dispatch.need witness
      | #Local_clock.Tag.r as witness ->
          Local_clock.Tag.give witness (module Local_clock_live)
      | [%hamlet.propagate_s.auto] -> .)
    local_requirement_source

let case_requirement_guarded =
  Combinators.provide
    ~handler:(fun requirement ->
      match requirement with
      | #Local_logger.Tag.r as witness when false ->
          Local_logger.Tag.give witness (module Local_logger_live)
      | #Local_clock.Tag.r as witness ->
          Local_clock.Tag.give witness (module Local_clock_live)
      | [%hamlet.propagate_s.auto] -> .)
    local_requirement_source

let case_requirement_cross_pipe =
  Automatic_propagation_external.requirement_program
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module struct
              let log _ = Hamlet.Combinators.return ()
            end)
      | [%hamlet.propagate_s.auto] -> .)

let case_requirement_dependent =
  local_requirement_source
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Local_logger.Tag.r as witness ->
          Local_logger.Tag.give witness (module Local_logger_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Local_clock.Tag.r as witness ->
          Local_clock.Tag.give witness (module Local_clock_live)
      | [%hamlet.propagate_s.auto] -> .)

type requirement_chain =
  [ Local_clock.Tag.r | Local_audit.Tag.r | Local_metrics.Tag.r ]

let case_requirement_chain_composition =
  let without_logger =
    local_requirement_source
    |> Combinators.provide ~handler:(fun requirement ->
        match requirement with
        | #Local_logger.Tag.r as witness ->
            Local_logger.Tag.give witness (module Local_logger_live)
        | [%hamlet.propagate_s.auto] -> .)
  in
  let with_metrics =
    let without_logger =
      (without_logger :> (string, Hamlet.never, requirement_chain) Hamlet.t)
    in
    let open Hamlet.Combinators in
    let* value = without_logger in
    let* (module Metrics) = Local_metrics.Tag.summon in
    return value
  in
  with_metrics
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Local_clock.Tag.r as witness ->
          Local_clock.Tag.give witness (module Local_clock_live)
      | [%hamlet.propagate_s.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Local_metrics.Tag.r as witness ->
          Local_metrics.Tag.give witness (module Local_metrics_live)
      | [%hamlet.propagate_s.auto] -> .)

let case_interleaved =
  mixed_source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Mixed_errors.a -> Hamlet.Combinators.return "a"
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      match requirement with
      | #Local_logger.Tag.r as witness ->
          Local_logger.Tag.give witness (module Local_logger_live)
      | [%hamlet.propagate_s.auto] -> .)

let case_recovery_requirement =
  recovery_requirement_source
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Exact_errors.a -> Local_audit.Tag.summon
      | [%hamlet.propagate_e.auto] -> .)
  |> Combinators.provide ~handler:(fun requirement ->
      (match requirement with
      | #Local_audit.Tag.r as witness ->
          Local_audit.Tag.give witness (module Local_audit_live)
      | [%hamlet.propagate_s.auto] -> .)
      [@warning "-11"])

let case_provision_error_then_catch =
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

let case_linear_cross_cu =
  Automatic_propagation_external.linear_program
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_external.Linear.Errors.e1 ->
          Hamlet.Combinators.return ()
      | #Automatic_propagation_external.Linear.Errors.e2 ->
          Hamlet.Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)

let case_error_wrapped =
  Automatic_propagation_wrapped.Wrapped_fixture.program
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #Automatic_propagation_wrapped.Wrapped_fixture.Remote.Errors.first ->
          Hamlet.Combinators.return "first"
      | [%hamlet.propagate_e.auto] -> .)
