open Hamlet

module Logger = Automatic_propagation_external.Logger

let source = Layer.make Logger.Tag.key (Combinators.fail `Missing)

let result =
  Layer.catch_cause source ~handler:(function [%hamlet.propagate_e.auto] -> .)
