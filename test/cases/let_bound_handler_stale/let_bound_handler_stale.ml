(* Fixture: let-bound handler. The handler [h] is defined separately and
   passed by name to [provide]; the walker must chase the [Texp_ident]
   back to the [Texp_function] definition.

   The input has only [`Console] in its services row, but [h] also has a
   forwarding arm for [`Logger] — that arm is the phantom. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "lbh_svc"

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let h = function `Console -> give key "impl" | `Logger -> need `Logger

let stale () = provide h (prog ())
