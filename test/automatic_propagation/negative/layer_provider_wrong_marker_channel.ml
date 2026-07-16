open Hamlet

module Logger = Automatic_propagation_external.Logger

module Logger_live = Logger.Make (struct
  let log _ = Combinators.return ()
end)

let provider =
  Layer.make Logger.Tag.key (Combinators.return (module Logger_live : Logger.S))

let result =
  Layer.provide_to_effect ~source:provider
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_e.auto] -> .)
    Logger.Tag.summon
