open Hamlet

module Producer = Hamlet_subtractor_generic_helper_producer
module Logger = Producer.Logger
module Clock = Producer.Clock

let source =
  let primary =
    Layer.make Logger.Tag.key
      (let open Combinators in
       let* _clock = Clock.Tag.summon in
       if Sys.opaque_identity true then fail `Source_a else fail `Source_b)
  in
  primary
  |> Layer.catch ~handler:(function
    | `Source_a ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Producer.Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)

let target =
  let errors =
    if Sys.opaque_identity true then Combinators.fail `Target_a
    else Combinators.fail `Target_b
  in
  let after_marker =
    errors
    |> Combinators.catch ~handler:(function
      | `Target_a -> Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)
  in
  let open Combinators in
  let* () = after_marker in
  let* logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  return logger

let invalid =
  Layer.provide_to_effect ~source
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | #Clock.Tag.r as witness -> Dispatch.need witness)
    target
  |> Combinators.catch ~handler:(function
    | `Source_b -> Combinators.return (module Producer.Logger_live : Logger.S)
    | [%hamlet.propagate_e.auto] -> .)
