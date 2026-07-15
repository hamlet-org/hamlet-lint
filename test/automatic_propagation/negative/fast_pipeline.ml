open Hamlet

module Errors = struct
  type handled = [ `Handled ]
  type residual = [ `Residual ]
  type error = [ handled | residual ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`Residual : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | #Errors.handled -> Combinators.return "handled"
      | [%hamlet.propagate_e.auto] -> .)
