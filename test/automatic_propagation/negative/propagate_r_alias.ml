open Hamlet

let source = Automatic_propagation_external.requirement_program

let result =
  Combinators.provide
    ~handler:(fun requirement ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (failwith "logger")
      | [%hamlet.propagate_r.auto] -> .)
    source
