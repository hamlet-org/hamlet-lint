(* Fixture: two arms, each matching a real input tag; the `Bar arm
   legitimately grows the output error row with [`Quux] via a direct
   [failure] in its body. No arm is stale; [`Quux] should be attributed
   to the second arm's body_introducers. Expected: zero findings. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo | `Bar ], 'r) Hamlet.t = failure `Foo

let _use () =
  catch (prog ()) ~f:(function `Foo -> success 0 | `Bar -> failure `Quux)
