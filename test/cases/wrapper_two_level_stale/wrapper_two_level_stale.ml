(* v0.1.2 P3: a two-level wrapper chain. [inner] is the direct latent
   wrapper around [provide] with a stale `Logger forwarding arm. [outer]
   is a wrapper that calls [inner] with its own parameter — the
   fixed-point promotes [outer] to a latent wrapper. The top-level use
   passes a concrete effect to [outer], so the finding lands at that
   call site. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

(* Direct latent wrapper. *)
let inner eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

(* Promoted by P3 fixed-point. *)
let outer eff = inner eff

(* Concrete effect with services_lb = {Console}. *)
let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let main () = outer (prog ())
