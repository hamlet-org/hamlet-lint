open Hamlet

let result =
  Combinators.catch Automatic_propagation_abstract.hidden_error_source
    ~handler:(fun error -> match error with [%hamlet.propagate_e.auto] -> .)
