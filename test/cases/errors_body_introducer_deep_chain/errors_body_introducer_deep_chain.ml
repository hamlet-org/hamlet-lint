(* v0.1.2 P2: chain of helpers, each calling the next, finally reaching
   [failure `Bar]. Verifies the recursive scanner traverses multiple
   levels within the depth-5 cap. Expected: 0 findings AND
   body_introduces=["Bar"]. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let level3 () : (int, [> `Bar ], 'r) Hamlet.t = failure `Bar

let level2 () : (int, [> `Bar ], 'r) Hamlet.t = level3 ()

let level1 () : (int, [> `Bar ], 'r) Hamlet.t = level2 ()

let _use () = catch (prog ()) ~f:(function `Foo -> level1 ())
