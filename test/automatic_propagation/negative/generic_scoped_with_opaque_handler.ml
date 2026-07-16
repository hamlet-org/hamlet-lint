let opaque_scope_handler _scope requirement = Hamlet.Dispatch.need requirement

let[@hamlet.generic] scoped_then_provide_logger logger source =
  source
  |> Hamlet.Combinators.scoped_with ~handler:opaque_scope_handler
  |> Hamlet.Combinators.provide ~handler:(function
    | #Hamlet_subtractor_generic_helper_producer.Logger.Tag.r as witness ->
        Hamlet_subtractor_generic_helper_producer.Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)
