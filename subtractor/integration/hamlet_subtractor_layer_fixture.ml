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

module Remote = Hamlet_subtractor_cross_cu_fixture.Remote

let primary : (Logger.Tag.t, errors, never) Layer.t =
  Layer.make Logger.Tag.key (Combinators.fail `Missing)

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
  Layer.make Logger.Tag.key (Combinators.fail `Connect_error)

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
