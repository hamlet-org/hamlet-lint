open Hamlet

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

module Logger_live = Logger.Make (struct
  let log _ = Combinators.return ()
end)

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) Hamlet.t
end]

[%%hamlet.service
module type Metrics = sig
  val emit : string -> (unit, 'e, 'r) Hamlet.t
end]

module Metrics_live = Metrics.Make (struct
  let emit _ = Combinators.return ()
end)

type errors = [ `Missing | `Timeout ]

module Structural_errors = struct
  type missing = [ `Layer_missing of string ]
  type timeout = [ `Layer_timeout of int ]
  type error = [ missing | timeout ]
end

module Trace_errors = struct
  type source = [ `Trace_missing | `Trace_timeout ]
  type recovery_missing = [ `Recovery_missing ]
  type recovery = [ `Recovery_missing | `Recovery_timeout ]
  type tap = [ `Tap_missing | `Tap_timeout ]
end

module Remote = Hamlet_subtractor_cross_cu_fixture.Remote

let primary : (Logger.Tag.t, errors, never) Layer.t =
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Missing
     else Combinators.fail `Timeout)

let fallback : (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  Layer.make Logger.Tag.key (Combinators.fail `Timeout)

let recovered : (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  Layer.catch primary ~handler:(function
    | `Missing -> fallback
    | [%hamlet.propagate_e.auto] -> .)

let recovered_pipe : (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  primary
  |> Layer.catch ~handler:(function
    | `Missing -> fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_catch_direct = recovered
let case_layer_catch_pipeline = recovered_pipe

let recovered_after_fresh : (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  Layer.catch (Layer.fresh primary) ~handler:(function
    | `Missing -> fallback
    | [%hamlet.propagate_e.auto] -> .)

let upstream_evaluations = ref 0

let counted_primary () =
  incr upstream_evaluations;
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Timeout
     else Combinators.fail `Missing)

let counted_layer =
  Layer.catch (counted_primary ()) ~handler:(function
    | `Missing -> fallback
    | [%hamlet.propagate_e.auto] -> .)

let counted_effect =
  Layer.provide_to_effect ~source:counted_layer
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger)
    Logger.Tag.summon

let named_primary : (Logger.Tag.t, Remote.Errors.error, never) Layer.t =
  Layer.make Logger.Tag.key
    (match Sys.opaque_identity 0 with
    | 0 -> Combinators.fail `Connect_error
    | 1 -> Combinators.fail (`Read_error "read")
    | _ -> Combinators.fail (`Write_error 1))

let named_fallback =
  Layer.make Logger.Tag.key (Combinators.return (module Logger_live : Logger.S))

let named_recovered :
    ( Logger.Tag.t,
      [ Remote.Errors.read_error | Remote.Errors.write_error ],
      never )
    Layer.t =
  Layer.catch named_primary ~handler:(function
    | #Remote.Errors.connect_error -> named_fallback
    | [%hamlet.propagate_e.auto] -> .)

let structural_primary : (Logger.Tag.t, Structural_errors.error, never) Layer.t
    =
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail (`Layer_timeout 42)
     else Combinators.fail (`Layer_missing "logger"))

let case_layer_structural :
    (Logger.Tag.t, Structural_errors.timeout, never) Layer.t =
  Layer.catch structural_primary ~handler:(function
    | `Layer_missing message ->
        let (_ : string) = message in
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let remote_primary choose : (Logger.Tag.t, Remote.Errors.error, never) Layer.t =
  Layer.make Logger.Tag.key
    (let open Combinators in
     let* () = Hamlet_subtractor_cross_cu_fixture.source choose in
     return (module Logger_live : Logger.S))

let layer_cross_cu_catalogue choose :
    ( Logger.Tag.t,
      [ Remote.Errors.read_error | Remote.Errors.write_error ],
      never )
    Layer.t =
  Layer.catch (remote_primary choose) ~handler:(function
    | #Remote.Errors.connect_error -> named_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_cross_cu_catalogue = layer_cross_cu_catalogue 1

let[@hamlet.generic] recover_missing source =
  Layer.catch source ~handler:(function
    | `Missing ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let generic_source =
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Missing
     else Combinators.fail `Timeout)

let generic_recovered : (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  recover_missing generic_source

let[@hamlet.generic] recover_timeout source =
  Layer.catch source ~handler:(function
    | `Timeout ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_missing_then_timeout source =
  recover_timeout (recover_missing source)

let generic_nested_source =
  Layer.make Logger.Tag.key
    (match Sys.opaque_identity 0 with
    | 0 -> Combinators.fail `Missing
    | 1 -> Combinators.fail `Timeout
    | _ -> Combinators.fail `Offline)

let case_layer_generic_same_module :
    (Logger.Tag.t, [ `Offline | `Timeout ], never) Layer.t =
  recover_missing generic_nested_source

let case_layer_generic_nested : (Logger.Tag.t, [ `Offline ], never) Layer.t =
  recover_missing_then_timeout generic_nested_source

let[@hamlet.generic] recover_unwrapped_missing source =
  Layer.unwrap Logger.Tag.key (Combinators.success source)
  |> Layer.catch ~handler:(function
    | `Missing ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let same_module_unwrapped_source =
  Layer.make Logger.Tag.key
    (match Sys.opaque_identity 2 with
    | 0 -> Combinators.fail `Missing
    | 1 -> Combinators.fail `Offline
    | _ -> Combinators.fail `Timeout)

let case_layer_generic_unwrap_same_module :
    (Logger.Tag.t, [ `Offline | `Timeout ], never) Layer.t =
  recover_unwrapped_missing same_module_unwrapped_source

let case_layer_generic_unwrap_output_to_later_marker :
    (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  case_layer_generic_unwrap_same_module
  |> Layer.catch ~handler:(function
    | `Offline ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let optional_direct_evaluations = ref 0
let optional_pipeline_evaluations = ref 0

let optional_source counter =
  incr counter;
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity false then Combinators.fail `Missing
     else Combinators.fail `Timeout)

let[@hamlet.generic] recover_optional_direct ?fresh source =
  Layer.catch ?fresh source ~handler:(function
    | `Missing ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_optional_pipeline ?fresh source =
  source
  |> Layer.catch ?fresh ~handler:(function
    | `Missing ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_optional_fresh_direct :
    (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  recover_optional_direct ~fresh:true
    (optional_source optional_direct_evaluations)

let case_layer_optional_fresh_pipeline :
    (Logger.Tag.t, [ `Timeout ], never) Layer.t =
  recover_optional_pipeline ~fresh:true
    (optional_source optional_pipeline_evaluations)

let target =
  let open Combinators in
  let* logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  return logger

let provided : (Logger.Tag.t, never, Clock.Tag.r) Hamlet.t =
  Layer.provide_to_effect
    ~source:
      (Layer.make Logger.Tag.key
         (Combinators.return (module Logger_live : Logger.S)))
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    target

let case_layer_provide_to_effect_direct = provided

let case_layer_provide_to_effect_pipeline :
    (Logger.Tag.t, never, Clock.Tag.r) Hamlet.t =
  target
  |> Layer.provide_to_effect
       ~source:
         (Layer.make Logger.Tag.key
            (Combinators.return (module Logger_live : Logger.S)))
       ~handler:(fun logger -> function
         | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
         | [%hamlet.propagate_s.auto] -> .)

let metrics_layer =
  Layer.make Metrics.Tag.key
    (let open Combinators in
     let* _logger = Logger.Tag.summon in
     let* _clock = Clock.Tag.summon in
     return (module Metrics_live : Metrics.S))

let provided_layer : (Metrics.Tag.t, never, Clock.Tag.r) Layer.t =
  Layer.provide_to_layer
    ~source:
      (Layer.make Logger.Tag.key
         (Combinators.return (module Logger_live : Logger.S)))
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    metrics_layer

let case_layer_provide_to_layer_direct = provided_layer

let case_layer_provide_to_layer_pipeline :
    (Metrics.Tag.t, never, Clock.Tag.r) Layer.t =
  metrics_layer
  |> Layer.provide_to_layer
       ~source:
         (Layer.make Logger.Tag.key
            (Combinators.return (module Logger_live : Logger.S)))
       ~handler:(fun logger -> function
         | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
         | [%hamlet.propagate_s.auto] -> .)

let provided_merge_layer : (Metrics.Tag.t, never, Clock.Tag.r) Layer.t =
  Layer.provide_merge_to_layer
    ~source:
      (Combinators.return
         object
           method logger = (module Logger_live : Logger.S)
         end)
    ~handler:(fun services -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness services#logger
      | [%hamlet.propagate_s.auto] -> .)
    metrics_layer

let merged_source =
  Combinators.return
    object
      method logger = (module Logger_live : Logger.S)
    end

let case_layer_provide_merge_to_layer_direct = provided_merge_layer

let case_layer_provide_merge_to_layer_pipeline :
    (Metrics.Tag.t, never, Clock.Tag.r) Layer.t =
  metrics_layer
  |> Layer.provide_merge_to_layer ~source:merged_source
       ~handler:(fun services -> function
       | #Logger.Tag.r as witness -> Logger.Tag.give witness services#logger
       | [%hamlet.propagate_s.auto] -> .)

let trace_source : (Logger.Tag.t, Trace_errors.source, never) Layer.t =
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Trace_timeout
     else Combinators.fail `Trace_missing)

let trace_fallback =
  Layer.make Logger.Tag.key (Combinators.return (module Logger_live : Logger.S))

let case_layer_trace_make : (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  Layer.catch trace_source ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_fresh : (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  Layer.catch (Layer.fresh trace_source) ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let trace_environment_key :
    < logger : (module Logger.S) > Layer.row Service_key.t =
  Service_key.make ~name:"trace-environment"

let trace_environment_build =
  let open Combinators in
  let* () =
    if Sys.opaque_identity true then fail `Trace_timeout
    else fail `Trace_missing
  in
  return
    object
      method logger = (module Logger_live : Logger.S)
    end

let trace_environment_fallback =
  Combinators.return
    object
      method logger = (module Logger_live : Logger.S)
    end

let case_layer_trace_merge_all :
    ( < logger : (module Logger.S) > Layer.row,
      [ `Trace_timeout ],
      never )
    Layer.t =
  Layer.catch (Layer.merge_all trace_environment_build) ~handler:(function
    | `Trace_missing -> Layer.merge_all trace_environment_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_merge_all_with_key :
    ( < logger : (module Logger.S) > Layer.row,
      [ `Trace_timeout ],
      never )
    Layer.t =
  Layer.catch
    (Layer.merge_all_with_key trace_environment_key trace_environment_build)
    ~handler:(function
    | `Trace_missing ->
        Layer.merge_all_with_key trace_environment_key
          trace_environment_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_or_die : (Logger.Tag.t, [ `Tap_timeout ], never) Layer.t =
  trace_source
  |> Layer.or_die
  |> Layer.tap ~f:(fun _logger ->
      if Sys.opaque_identity true then Combinators.fail `Tap_timeout
      else Combinators.fail `Tap_missing)
  |> Layer.catch ~handler:(function
    | `Tap_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_catch_defect :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  trace_source
  |> Layer.catch_defect ~handler:(fun _die -> trace_source)
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_catch_cause :
    (Logger.Tag.t, [ `Recovery_timeout ], never) Layer.t =
  trace_source
  |> Layer.catch_cause ~handler:(fun _cause ->
      Layer.make Logger.Tag.key
        (if Sys.opaque_identity true then Combinators.fail `Recovery_timeout
         else Combinators.fail `Recovery_missing))
  |> Layer.catch ~handler:(function
    | `Recovery_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_tap : (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  trace_source
  |> Layer.tap ~f:(fun _logger -> Combinators.return ())
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_tap_fail :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  trace_source
  |> Layer.tap_fail ~f:(fun _error -> Combinators.return ())
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_tap_defect :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  trace_source
  |> Layer.tap_defect ~f:(fun _die -> Combinators.return ())
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let case_layer_trace_tap_cause :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  trace_source
  |> Layer.tap_cause ~f:(fun _cause -> Combinators.return ())
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let transparent_layer_effect = Combinators.return trace_source

let case_layer_trace_unwrap : (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t
    =
  Layer.unwrap Logger.Tag.key transparent_layer_effect
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let choose_layer () :
    ( (Logger.Tag.t, Trace_errors.source, never) Layer.t,
      Trace_errors.source,
      never )
    Hamlet.t =
  Combinators.return trace_source

let case_layer_trace_unwrap_builder :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  Layer.unwrap Logger.Tag.key (choose_layer ())
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let effect_marker_inside_layer =
  (if Sys.opaque_identity true then Combinators.fail `Trace_timeout
   else Combinators.fail `Trace_missing)
  |> Combinators.catch ~handler:(function
    | `Trace_missing -> Combinators.fail `Recovery_missing
    | [%hamlet.propagate_e.auto] -> .)

let case_mixed_effect_marker_then_layer_marker :
    (Logger.Tag.t, [ `Trace_timeout ], never) Layer.t =
  Layer.make Logger.Tag.key effect_marker_inside_layer
  |> Layer.catch ~handler:(function
    | `Recovery_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)

let mixed_layer_source :
    ( Logger.Tag.t,
      [ Trace_errors.source | Trace_errors.recovery_missing ],
      never )
    Layer.t =
  Layer.make Logger.Tag.key
    (match Sys.opaque_identity 0 with
    | 0 -> Combinators.fail `Trace_missing
    | 1 -> Combinators.fail `Trace_timeout
    | _ -> Combinators.fail `Recovery_missing)

let mixed_after_layer_marker :
    ( Logger.Tag.t,
      [ `Trace_timeout | Trace_errors.recovery_missing ],
      never )
    Layer.t =
  mixed_layer_source
  |> Layer.catch ~handler:(function
    | `Trace_missing -> trace_fallback
    | [%hamlet.propagate_e.auto] -> .)
