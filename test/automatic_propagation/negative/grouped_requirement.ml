open Hamlet

let result =
  Combinators.provide
    ~handler:(fun requirement ->
      match requirement with [%hamlet.propagate_s.auto] -> .)
    Automatic_propagation_abstract.grouped_requirement_source
