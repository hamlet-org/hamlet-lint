open Hamlet

module Errors = struct
  type a = [ `A ]
  type b = [ `B ]
  type error = [ a | b ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`B : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | [%hamlet.propagate_e.auto] -> .
      | #Errors.a -> Combinators.return "a")
