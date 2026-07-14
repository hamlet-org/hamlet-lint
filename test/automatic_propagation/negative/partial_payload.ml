open Hamlet

module Errors = struct
  type pair = [ `Pair of string * int ]
  type residual = [ `Residual ]
  type error = [ pair | residual ]
end

let source : (string, Errors.error, never) t =
  Combinators.fail (`Residual : Errors.error)

let result =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | `Pair (_, _) -> Combinators.return "pair"
      | [%hamlet.propagate_e.auto] -> .)
