(* Fixture: the top-level binding [h] is itself a [let inner = function ...
   in inner] expression. Resolution must recurse through the [Texp_let]
   body. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "nlh_svc"

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let h =
  let inner = function
    | `Console -> give key "impl"
    | `Logger -> need `Logger
  in
  inner

let stale () = provide h (prog ())
