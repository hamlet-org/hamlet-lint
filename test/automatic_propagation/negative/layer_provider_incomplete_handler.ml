open Hamlet

module Logger = Hamlet_subtractor_generic_helper_producer.Logger
module Clock = Hamlet_subtractor_generic_helper_producer.Clock

let source =
  Layer.make Logger.Tag.key
    (let open Combinators in
     let* _clock = Clock.Tag.summon in
     if Sys.opaque_identity true then fail `Source_a else fail `Source_b)

let target =
  let open Combinators in
  let* logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  return logger

let invalid =
  Layer.provide_to_effect ~source
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | #Clock.Tag.r as witness when false -> Dispatch.need witness)
    target
  |> Combinators.catch ~handler:(function
    | `Source_a ->
        Combinators.return
          (module Hamlet_subtractor_generic_helper_producer.Logger_live
          : Logger.S)
    | [%hamlet.propagate_e.auto] -> .)
