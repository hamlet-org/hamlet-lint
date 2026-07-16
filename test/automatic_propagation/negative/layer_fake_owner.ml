open Hamlet

module Logger = Automatic_propagation_external.Logger

let source =
  Hamlet.Layer.make Logger.Tag.key
    (if Sys.opaque_identity true then Combinators.fail `Missing
     else Combinators.fail `Timeout)

module Fake_layer = struct
  let catch source ~handler:_ = source
end

let result =
  Fake_layer.catch source ~handler:(function
    | `Missing -> source
    | [%hamlet.propagate_e.auto] -> .)
