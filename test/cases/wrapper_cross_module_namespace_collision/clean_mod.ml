(* This module's [wrap] forwards `Logger but the wrapper is only ever
   called with effects that already need `Logger, so there is nothing
   stale about it. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "clean_svc"

let wrap eff =
  provide (function `Console -> give key "impl" | `Logger -> need `Logger) eff
