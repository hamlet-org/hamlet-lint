open Hamlet

module Logger = Automatic_propagation_external.Logger

let recover_selected selected =
  Layer.unwrap Logger.Tag.key (Combinators.return selected)
  |> Layer.catch ~handler:(function
    | `Missing -> selected
    | [%hamlet.propagate_e.auto] -> .)
