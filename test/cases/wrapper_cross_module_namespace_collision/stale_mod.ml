(* v0.1.2 P1: two modules each define a function called [wrap]. The v0.1.1
   "last path component only" shortcut would falsely match calls to the
   clean [wrap] against the stale [wrap]'s latent site. The new canonical
   full-path key prevents that.

   This module's [wrap] has a stale `Logger forwarding arm. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "stale_svc"

let wrap eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff
