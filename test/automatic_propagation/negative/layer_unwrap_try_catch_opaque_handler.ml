open Hamlet

module Producer = Hamlet_subtractor_generic_helper_producer

let opaque_handler _ = `Try_catch_build

let selected =
  Layer.make Producer.Logger.Tag.key
    (Combinators.try_catch
       ~thunk:(fun () -> (module Producer.Logger_live : Producer.Logger.S))
       ~handler:opaque_handler)

let _ =
  Layer.unwrap Producer.Logger.Tag.key (Combinators.return selected)
  |> Layer.catch ~handler:(function
    | `Try_catch_build -> Producer.logger_layer
    | [%hamlet.propagate_e.auto] -> .)
