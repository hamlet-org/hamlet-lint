(* Fixture for v0.1.1: an in-module alias [let my_provide =
   Combinators.provide] must still be recognised as a services-row provide
   site by the walker's Path-based matcher, which pre-scans the structure
   for such bindings. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "aliased_svc"

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

(* Alias. After the walker's pre-scan this name resolves to the
   Combinators.provide entry. *)
let my_provide = provide

(* Stale forwarding arm for `Logger: input effect only has `Console in
   services_lb, so the `Logger arm is a phantom-introducing forward. *)
let stale () =
  my_provide
    (function `Console -> give key "impl" | `Logger -> need `Logger)
    (prog ())
