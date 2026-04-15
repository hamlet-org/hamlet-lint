(* v0.1.2 P2: cross-module transitive body introducer. The arm body calls
   [Helpers.raise_bar], which is a [Pdot] reference resolved through the
   load-set-wide global handler env. Expected: 0 findings AND
   body_introduces=["Bar"]. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let _use () = catch (prog ()) ~f:(function `Foo -> Helpers.raise_bar ())
