(* Caller module: passes [Handler_mod.h] to [provide]. The walker must
   resolve the Pdot cross-module reference and inspect the arms of
   [Handler_mod.h] defined in [handler_mod.ml]. *)

open Hamlet.Combinators

let prog () : (string, 'e, [> `Console ]) Hamlet.t =
  summon Handler_mod.key `Console

let stale () = provide Handler_mod.h (prog ())
