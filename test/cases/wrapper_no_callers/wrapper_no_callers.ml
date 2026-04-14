(* Fixture: a wrapper with a stale-looking forwarding arm but no callers
   in the same cmt. Latent site is emitted but has zero matching call
   sites, so the analyzer drops it silently (§2.6). Expect: 0 findings. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let p eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

(* No caller of [p] in this module. The wrapper stays dormant. *)
let _ = p
