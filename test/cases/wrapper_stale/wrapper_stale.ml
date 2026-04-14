(* Fixture: a wrapper function whose subject effect is a free row variable,
   called from another function with a concrete argument.

   The wrapper's [Combinators.provide] is classified as a latent site; the
   call in [main] is a matching call site. After join, the phantom
   `Logger tag is attributed to the call site, not to [p]'s definition. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

(* Wrapper. eff has a free row variable 'r — latent site. *)
let p eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

(* Concrete input whose services_lb is exactly {Console}. *)
let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

(* Call site: passes a concrete effect. The phantom `Logger should be
   reported HERE, not at the definition of [p]. *)
let main () = p (prog ())
