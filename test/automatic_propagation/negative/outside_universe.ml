open Hamlet

module Errors = struct
  type a = [ `A ]
  type b = [ `B ]
  type outside = [ `Outside ]
  type error = [ a | b ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`B : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | #Errors.outside -> Combinators.return "outside"
      | #Errors.a -> Combinators.return "a"
      | [%hamlet.propagate_e.auto] -> .)
