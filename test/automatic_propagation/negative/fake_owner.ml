open Hamlet

module Errors = struct
  type only = [ `Only ]
end

let source : (string, Errors.only, never) t = Combinators.fail `Only

let catch source ~handler:_ = source

let result =
  catch source ~handler:(fun error ->
      match error with
      | #Errors.only -> Combinators.return "handled"
      | [%hamlet.propagate_e.auto] -> .)
