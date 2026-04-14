(* v0.1.2 P2: mutually recursive helpers form a cycle. Without the
   visited-set short-circuit the body-introducer scanner would recurse
   infinitely on this input; the test's purpose is to pin that the
   walker terminates.

   The conservative fallback contributes nothing for the cycle path. *)

open Hamlet.Combinators

let rec ping () : (int, [> `Bar ], 'r) Hamlet.t = pong ()

and pong () : (int, [> `Bar ], 'r) Hamlet.t = ping ()

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let _use () = catch (prog ()) ~f:(function `Foo -> ping ())
