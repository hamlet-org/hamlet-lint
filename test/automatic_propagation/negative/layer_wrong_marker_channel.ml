open Hamlet

module Logger = Automatic_propagation_external.Logger

let source =
  Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Missing
     else Combinators.fail `Timeout)

let result =
  Layer.catch source ~handler:(function
    | `Missing -> source
    | [%hamlet.propagate_s.auto] -> .)
