(* v0.1.2 P3: mutually recursive wrappers. [p] calls [q] in the
   non-base branch and the base branch falls through to [q]; [q]
   directly wraps [provide] with the stale `Logger arm. The
   fixed-point promotes [q] (direct) then [p] (via [q]) and converges.

   Tests that the monotonic merge handles let-rec without hanging. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let rec p eff = if true then q eff else p eff

and q eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let main () = p (prog ())
