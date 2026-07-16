[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.fail `Recovery
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] provide_logger logger source =
  source
  |> Hamlet.Combinators.provide ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)

let[@hamlet.generic] alternating logger source =
  Hamlet.Combinators.provide
    (Hamlet.Combinators.catch source ~handler:(function
      | `Missing -> Hamlet.Combinators.fail `Recovery
      | [%hamlet.propagate_e.auto] -> .))
    ~handler:(function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)

let[@hamlet.generic] guarded enabled source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing when enabled -> Hamlet.Combinators.success ()
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_timeout source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Timeout -> Hamlet.Combinators.fail `After_timeout
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_through_same_unit source = recover_missing source

let[@hamlet.generic] recover_twice_nested source =
  recover_timeout (recover_missing source)

let[@hamlet.generic] recover_labelled ~value source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return value
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_cause_same_module replacement source =
  source
  |> Hamlet.Combinators.catch_cause ~handler:(fun _cause ->
      if replacement then Hamlet.Combinators.fail `Cause_recovered
      else Hamlet.Combinators.fail `Cause_residual)
  |> Hamlet.Combinators.catch ~handler:(function
    | `Cause_recovered -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] nested_and_local logger source =
  Hamlet.Combinators.catch
    (recover_timeout
       (Hamlet.Combinators.provide (recover_missing source) ~handler:(function
         | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
         | [%hamlet.propagate_s.auto] -> .)))
    ~handler:(function
      | `Recovery -> Hamlet.Combinators.return ()
      | `After_timeout -> Hamlet.Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)

type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]
type third_errors = [ `Missing | `Offline | `Timeout ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let inferred_first_source =
  if Sys.opaque_identity true then Hamlet.Combinators.fail `Missing
  else Hamlet.Combinators.fail `Timeout

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let labelled_source : (string, second_errors, Hamlet.never) Hamlet.t =
  assert false

let third_source : (unit, third_errors, Hamlet.never) Hamlet.t = assert false

module Logger_live = Logger.Make (struct
  let log _ = Hamlet.Combinators.return ()
end)

let nested_requirement_source : (unit, third_errors, Logger.Tag.r) Hamlet.t =
  assert false

let first_specialization :
    (unit, [ `Recovery | `Timeout ], Hamlet.never) Hamlet.t =
  recover_missing first_source

let second_specialization :
    (unit, [ `Offline | `Recovery ], Hamlet.never) Hamlet.t =
  recover_missing second_source

let third_specialization :
    (unit, [ `Offline | `Recovery | `Timeout ], Hamlet.never) Hamlet.t =
  recover_missing third_source

let same_unit_specialization :
    (unit, [ `Recovery | `Timeout ], Hamlet.never) Hamlet.t =
  recover_through_same_unit first_source

let twice_nested_specialization :
    (unit, [ `After_timeout | `Offline | `Recovery ], Hamlet.never) Hamlet.t =
  recover_twice_nested third_source

let labelled_specialization : (string, [ `Offline ], Hamlet.never) Hamlet.t =
  recover_labelled ~value:"missing" labelled_source

let catch_cause_same_module_specialization :
    (unit, [ `Cause_residual ], Hamlet.never) Hamlet.t =
  recover_cause_same_module false third_source

let nested_and_local_specialization :
    (unit, [ `Offline ], Hamlet.never) Hamlet.t =
  nested_and_local (module Logger_live) nested_requirement_source

let generic_output_to_literal_error_marker :
    (unit, [ `Timeout ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.catch (recover_missing inferred_first_source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let nested_generic_output_to_literal_error_marker :
    (unit, [ `After_timeout | `Offline ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.catch (recover_twice_nested third_source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let ordinary_identity value = value

let ordinary_direct_call = ordinary_identity 42

let ordinary_effect source = Hamlet.Combinators.map source ~f:Fun.id

let ordinary_effect_call : (unit, first_errors, Hamlet.never) Hamlet.t =
  ordinary_effect first_source

let direct_combinator_use =
  Hamlet.Combinators.catch (recover_missing first_source) ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let first_handled =
  Hamlet.Combinators.catch first_specialization ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())
