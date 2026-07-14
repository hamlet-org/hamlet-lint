type hidden_error

val hidden_error_source : (string, hidden_error, Hamlet.never) Hamlet.t

type grouped_requirement =
  [ Automatic_propagation_external.Logger.Tag.r | Automatic_propagation_external.Clock.Tag.r ]

val grouped_requirement_source :
  (unit, Hamlet.never, grouped_requirement) Hamlet.t
