(* v0.1.2 P3: two-level wrapper chain, but the top-level call passes an
   effect that legitimately needs the forwarded `Logger tag, so the
   forward is justified and there is no finding. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let inner eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

let outer eff = inner eff

let prog () : (string, 'e, [> `Console | `Logger ]) Hamlet.t =
  let* _ = summon key `Console in
  summon key `Logger

let main () = outer (prog ())
