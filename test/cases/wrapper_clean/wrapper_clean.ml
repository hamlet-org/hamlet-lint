(* Fixture: a wrapper whose handler forwards `Logger but is called with an
   effect that already needs `Logger — the forward is legitimate, no
   finding. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let p eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

let prog () : (string, 'e, [> `Console | `Logger ]) Hamlet.t =
  let* _ = summon key `Console in
  summon key `Logger

let main () = p (prog ())
