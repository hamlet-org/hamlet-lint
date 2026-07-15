open Hamlet

module Errors = struct
  type a = [ `A ]
  type b = [ `B ]
  type error = [ a | b ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`A : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | #Errors.a -> Combinators.return "a"
      | #Errors.b -> Combinators.return "b"
      | [%hamlet.propagate_e.auto] -> .)
