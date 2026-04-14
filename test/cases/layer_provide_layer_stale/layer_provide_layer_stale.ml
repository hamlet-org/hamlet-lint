(* Fixture: [Hamlet.Layer.provide_layer dep ~handler con] with a stale
   forwarding arm. Subject for row analysis is the consumer layer [con]. *)

open Hamlet.Combinators

let key_dep : (_, string) Hamlet.Service.key = Hamlet.Service.make "dep"
let key_svc : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let dep_layer () : (string, 'e, 'r) Hamlet.Layer.layer =
  Hamlet.Layer.make key_dep (success "dep-impl")

(* Consumer layer whose build effect summons the dep service, constraining
   its 'r row to [> `Console ]. *)
let con_layer () : (string, 'e, [> `Console ]) Hamlet.Layer.layer =
  Hamlet.Layer.make key_svc (summon key_dep `Console)

let stale () =
  Hamlet.Layer.provide_layer (dep_layer ())
    ~handler:(fun impl -> function
      | `Console -> give key_dep impl | `Logger -> need `Logger)
    (con_layer ())
