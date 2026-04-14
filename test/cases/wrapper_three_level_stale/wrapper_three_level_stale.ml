(* v0.1.2 P3: four-level wrapper chain. The fixed-point must run multiple
   passes to promote level3 (calls level4), level2 (calls level3), and
   level1 (calls level2) up to latent status, starting from level4 which
   directly wraps [provide] with the stale `Logger arm. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let level4 eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

let level3 eff = level4 eff
let level2 eff = level3 eff
let level1 eff = level2 eff

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let main () = level1 (prog ())
