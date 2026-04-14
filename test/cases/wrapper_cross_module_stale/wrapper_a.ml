(* v0.1.2 P1: wrapper defined in module A, used from module B.
   The wrapper has a stale forwarding arm. Its latent_site is keyed by
   the canonical dotted path of the enclosing function so that the
   call_site emitted in module B joins by full identity rather than by
   "last component only". *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "xmw_svc"

(* Latent wrapper: subject [eff] is the enclosing function's parameter. *)
let wrap eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff
