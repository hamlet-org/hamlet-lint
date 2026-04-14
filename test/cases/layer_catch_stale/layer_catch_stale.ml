(* Fixture: [Hamlet.Layer.catch primary ~f] with stale forwarding arms on
   the errors row. *)

open Hamlet.Combinators

let key : (_, int) Hamlet.Service.key = Hamlet.Service.make "svc"

(* Primary layer whose build effect fails with a `NotFound error only. *)
let primary () : (int, [> `NotFound ], 'r) Hamlet.Layer.layer =
  Hamlet.Layer.make key (failure `NotFound)

let stale () =
  Hamlet.Layer.catch (primary ()) ~f:(function
    | `NotFound -> Hamlet.Layer.make key (success 0)
    | `Timeout -> Hamlet.Layer.make key (failure `Timeout)
    | `Forbidden -> Hamlet.Layer.make key (failure `Forbidden))
