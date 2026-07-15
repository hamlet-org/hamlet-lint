open Hamlet

let ( let* ) = Combinators.( let* )

type hidden_error = [ `Hidden_error ]

let hidden_error_source : (string, hidden_error, never) t =
  Combinators.fail `Hidden_error

type grouped_requirement =
  [ Automatic_propagation_external.Logger.Tag.r
  | Automatic_propagation_external.Clock.Tag.r ]

let grouped_requirement_source : (unit, never, grouped_requirement) t =
  let* _logger = Automatic_propagation_external.Logger.Tag.summon in
  let* _clock = Automatic_propagation_external.Clock.Tag.summon in
  Combinators.return ()
