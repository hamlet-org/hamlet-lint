(* Handler definition lives here; the caller module references
   [Handler_mod.h] via Pdot. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "xmh_svc"

let h = function `Console -> give key "impl" | `Logger -> need `Logger
