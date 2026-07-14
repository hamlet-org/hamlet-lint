open Hamlet

module Errors = struct
  type handled = [ `Handled ]
end

let handle (source : (string, [> Errors.handled ], never) t) =
  Combinators.catch source ~handler:(fun error ->
      match error with
      | #Errors.handled -> Combinators.return "handled"
      | [%hamlet.propagate_e.auto] -> .)
