(* Fixture: [Hamlet.Layer.provide layer ~handler consumer] with a stale
   forwarding arm on the services row. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let layer () : (string, 'e, 'r) Hamlet.Layer.layer =
  Hamlet.Layer.make key (success "impl")

let consumer () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

(* Stale forwarding arm for `Logger. *)
let stale () =
  Hamlet.Layer.provide (layer ())
    ~handler:(fun impl -> function
      | `Console -> give key impl | `Logger -> need `Logger)
    (consumer ())
