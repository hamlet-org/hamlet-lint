let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.fail `Recovery
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_missing_to_unit source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_cause replacement source =
  source
  |> Hamlet.Combinators.catch_cause ~handler:(fun _cause ->
      if replacement then Hamlet.Combinators.fail `Cause_recovered
      else Hamlet.Combinators.fail `Cause_residual)
  |> Hamlet.Combinators.catch ~handler:(function
    | `Cause_recovered -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) Hamlet.t
end]

[%%hamlet.service
module type Metrics = sig
  val emit : string -> (unit, 'e, 'r) Hamlet.t
end]

module Logger_live = Logger.Make (struct
  let log _ = Hamlet.Combinators.return ()
end)

module Metrics_live = Metrics.Make (struct
  let emit _ = Hamlet.Combinators.return ()
end)

let[@hamlet.generic] recover_layer_missing source =
  Hamlet.Layer.catch source ~handler:(function
    | `Missing ->
        Hamlet.Layer.make Logger.Tag.key
          (Hamlet.Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_layer_missing_and_offline source =
  Hamlet.Layer.catch (recover_layer_missing source) ~handler:(function
    | `Offline ->
        Hamlet.Layer.make Logger.Tag.key
          (Hamlet.Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_unwrapped_layer_missing source =
  Hamlet.Layer.unwrap Logger.Tag.key (Hamlet.Combinators.return source)
  |> Hamlet.Layer.catch ~handler:(function
    | `Missing ->
        Hamlet.Layer.make Logger.Tag.key
          (Hamlet.Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let logger_layer =
  Hamlet.Layer.make Logger.Tag.key
    (Hamlet.Combinators.return (module Logger_live : Logger.S))

let merged_logger_source =
  Hamlet.Combinators.return
    object
      method logger = (module Logger_live : Logger.S)
    end

let[@hamlet.generic] provide_logger_layer_to_effect target =
  Hamlet.Layer.provide_to_effect ~source:logger_layer
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    target

let[@hamlet.generic] provide_logger_layer_to_layer target =
  Hamlet.Layer.provide_to_layer ~source:logger_layer
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    target

let[@hamlet.generic] provide_logger_merge_to_layer target =
  Hamlet.Layer.provide_merge_to_layer ~source:merged_logger_source
    ~handler:(fun services -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness services#logger
      | [%hamlet.propagate_s.auto] -> .)
    target

let[@hamlet.generic] provide_logger logger source =
  Hamlet.Combinators.provide source ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)

module Ordinary = struct
  let add left right = left + right
  let identity value = value
end
