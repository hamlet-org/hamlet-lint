(* Fixture: handler reached through an alias chain.

   [h1] is the actual function; [h] is just a name for [h1]. The walker
   must chase [h -> h1 -> function ...] to reach the [Texp_function]. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "ah_svc"

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let h1 = function `Console -> give key "impl" | `Logger -> need `Logger

let h = h1

let stale () = provide h (prog ())
