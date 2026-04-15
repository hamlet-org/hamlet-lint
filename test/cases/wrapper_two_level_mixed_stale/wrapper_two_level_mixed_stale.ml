(* v0.1.2 P3: two distinct two-level promotion chains coexisting in one
   compilation unit. [outer_a] wraps [inner_stale] (forwards `Logger),
   [outer_b] wraps [inner_clean] (forwards `Database). The fixed-point
   promotes both [outer_*] independently with the right exemplar's row
   shape. [main] calls each wrapper with a concrete effect that exercises
   exactly one of them as stale.

   Verifies that the fixed-point keeps distinct wrapper chains apart
   and that a clean call neither steals nor masks a stale finding. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let inner_stale eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

let inner_clean eff =
  provide
    (function `Console -> give key "impl" | `Database -> need `Database)
    eff

let outer_a eff = inner_stale eff
let outer_b eff = inner_clean eff

(* For [outer_a]: services_lb = {Console}, so `Logger forward is stale. *)
let prog_a () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

(* For [outer_b]: services_lb already needs `Database, clean. *)
let prog_b () : (string, 'e, [> `Console | `Database ]) Hamlet.t =
  let* _ = summon key `Console in
  summon key `Database

let main () =
  let _ = outer_a (prog_a ()) in
  outer_b (prog_b ())
