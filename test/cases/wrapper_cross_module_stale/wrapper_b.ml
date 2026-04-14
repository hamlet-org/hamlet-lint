(* Caller of [Wrapper_a.wrap]. Passes a concrete effect whose services_lb
   is exactly {Console}, so the `Logger forwarding arm of [wrap] is
   stale and the finding should land HERE in this file at the call site. *)

open Hamlet.Combinators

let prog () : (string, 'e, [> `Console ]) Hamlet.t =
  summon Wrapper_a.key `Console

let main () = Wrapper_a.wrap (prog ())
