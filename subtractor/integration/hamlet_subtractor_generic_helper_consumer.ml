type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]
type third_errors = [ `Missing | `Offline | `Timeout ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let inferred_first_source =
  if Sys.opaque_identity true then Hamlet.Combinators.fail `Missing
  else Hamlet.Combinators.fail `Timeout

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let third_source : (unit, third_errors, Hamlet.never) Hamlet.t = assert false

let layer_source =
  Hamlet.Layer.make Hamlet_subtractor_generic_helper_producer.Logger.Tag.key
    (if Sys.opaque_identity true then Hamlet.Combinators.fail `Missing
     else Hamlet.Combinators.fail `Timeout)

let cross_module_layer_generic :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      [ `Timeout ],
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.recover_layer_missing layer_source

let case_layer_generic_cross_module = cross_module_layer_generic

type extended_layer_errors = [ `Missing | `Offline | `Timeout ]

let extended_layer_source :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      extended_layer_errors,
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet.Layer.make Hamlet_subtractor_generic_helper_producer.Logger.Tag.key
    (match Sys.opaque_identity 0 with
    | 0 -> Hamlet.Combinators.fail `Missing
    | 1 -> Hamlet.Combinators.fail `Offline
    | _ -> Hamlet.Combinators.fail `Timeout)

let case_layer_generic_nested_cross_module :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      [ `Timeout ],
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.recover_layer_missing_and_offline
    extended_layer_source

let case_layer_generic_output_to_later_marker :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      [ `Timeout ],
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.recover_layer_missing
    extended_layer_source
  |> Hamlet.Layer.catch ~handler:(function
    | `Offline ->
        Hamlet.Layer.make
          Hamlet_subtractor_generic_helper_producer.Logger.Tag.key
          (Hamlet.Combinators.return
             (module Hamlet_subtractor_generic_helper_producer.Logger_live
             : Hamlet_subtractor_generic_helper_producer.Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let unwrapped_layer_source :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      extended_layer_errors,
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet.Layer.make Hamlet_subtractor_generic_helper_producer.Logger.Tag.key
    (match Sys.opaque_identity 2 with
    | 0 -> Hamlet.Combinators.fail `Missing
    | 1 -> Hamlet.Combinators.fail `Offline
    | _ -> Hamlet.Combinators.fail `Timeout)

let case_layer_generic_unwrap_cross_module :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      [ `Offline | `Timeout ],
      Hamlet.never )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.recover_unwrapped_layer_missing
    unwrapped_layer_source

let case_layer_generic_unwrap_output_to_later_marker :
    ( Hamlet_subtractor_generic_helper_producer.Logger.Tag.t,
      [ `Timeout ],
      Hamlet.never )
    Hamlet.Layer.t =
  case_layer_generic_unwrap_cross_module
  |> Hamlet.Layer.catch ~handler:(function
    | `Offline ->
        Hamlet.Layer.make
          Hamlet_subtractor_generic_helper_producer.Logger.Tag.key
          (Hamlet.Combinators.return
             (module Hamlet_subtractor_generic_helper_producer.Logger_live
             : Hamlet_subtractor_generic_helper_producer.Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let generic_layer_provider_target =
  let open Hamlet.Combinators in
  let* _logger = Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon in
  let* _clock = Hamlet_subtractor_generic_helper_producer.Clock.Tag.summon in
  return ()

let case_layer_generic_provide_to_effect :
    ( unit,
      Hamlet.never,
      Hamlet_subtractor_generic_helper_producer.Clock.Tag.r )
    Hamlet.t =
  Hamlet_subtractor_generic_helper_producer.provide_logger_layer_to_effect
    generic_layer_provider_target

let generic_layer_provider_target_layer =
  Hamlet.Layer.make Hamlet_subtractor_generic_helper_producer.Metrics.Tag.key
    (let open Hamlet.Combinators in
     let* _logger =
       Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon
     in
     let* _clock = Hamlet_subtractor_generic_helper_producer.Clock.Tag.summon in
     return
       (module Hamlet_subtractor_generic_helper_producer.Metrics_live
       : Hamlet_subtractor_generic_helper_producer.Metrics.S))

let case_layer_generic_provide_to_layer :
    ( Hamlet_subtractor_generic_helper_producer.Metrics.Tag.t,
      Hamlet.never,
      Hamlet_subtractor_generic_helper_producer.Clock.Tag.r )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.provide_logger_layer_to_layer
    generic_layer_provider_target_layer

let case_layer_generic_provide_merge_to_layer :
    ( Hamlet_subtractor_generic_helper_producer.Metrics.Tag.t,
      Hamlet.never,
      Hamlet_subtractor_generic_helper_producer.Clock.Tag.r )
    Hamlet.Layer.t =
  Hamlet_subtractor_generic_helper_producer.provide_logger_merge_to_layer
    generic_layer_provider_target_layer

let case_generic_first =
  Hamlet_subtractor_generic_helper_producer.recover_missing first_source

let case_generic_second =
  Hamlet_subtractor_generic_helper_producer.recover_missing second_source

let scoped_requirement_source =
  let open Hamlet.Combinators in
  let* () = add_finalizer (return ()) in
  let* _logger = Hamlet_subtractor_generic_helper_producer.Logger.Tag.summon in
  let* _metrics =
    Hamlet_subtractor_generic_helper_producer.Metrics.Tag.summon
  in
  let* _clock = Hamlet_subtractor_generic_helper_producer.Clock.Tag.summon in
  return ()

let case_generic_scoped_with_cross_module :
    ( unit,
      Hamlet.never,
      Hamlet_subtractor_generic_helper_producer.Clock.Tag.r )
    Hamlet.t =
  Hamlet_subtractor_generic_helper_producer.scoped_then_provide_metrics
    (module Hamlet_subtractor_generic_helper_producer.Logger_live)
    scoped_requirement_source

let generic_first_handled =
  Hamlet.Combinators.catch case_generic_first ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let generic_direct_inside_catch =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing
       inferred_first_source) ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let generic_direct_inside_chain =
  Hamlet.Combinators.chain
    (Hamlet_subtractor_generic_helper_producer.recover_missing second_source)
    ~handler:(fun () -> Hamlet.Combinators.return "done")

let generic_output_to_error_marker : (unit, [ `Timeout ], Hamlet.never) Hamlet.t
    =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing first_source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let generic_output_feeds_following_marker :
    (unit, [ `Timeout ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing_to_unit
       third_source) ~handler:(function
    | `Offline -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let case_generic_catch_cause_cross_module :
    (unit, [ `Cause_residual ], Hamlet.never) Hamlet.t =
  Hamlet_subtractor_generic_helper_producer.recover_cause false third_source

let ordinary_qualified_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.add 20 22

let ordinary_qualified_nested_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.identity
    (Hamlet_subtractor_generic_helper_producer.Ordinary.add 1 2)
