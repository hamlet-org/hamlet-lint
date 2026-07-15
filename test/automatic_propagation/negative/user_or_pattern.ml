open Hamlet

module Errors = struct
  type a = [ `A ]
  type b = [ `B ]
  type c = [ `C ]
  type error = [ a | b | c ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`C : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | `A | `B -> Combinators.return "handled"
      | [%hamlet.propagate_e.auto] -> .)
