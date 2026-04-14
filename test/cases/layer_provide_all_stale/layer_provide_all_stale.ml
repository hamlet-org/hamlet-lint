(* Fixture: [Hamlet.Layer.provide_all ~handler ~build consumer] with a
   stale forwarding arm on the services row. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "svc"

let consumer () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let stale () =
  Hamlet.Layer.provide_all
    ~handler:(fun env -> function
      | `Console -> give key env#console | `Logger -> need `Logger)
    ~build:
      (success
         object
           method console = "impl"
         end)
    (consumer ())
