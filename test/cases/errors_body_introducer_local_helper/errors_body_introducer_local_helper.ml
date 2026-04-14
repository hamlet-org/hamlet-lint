(* v0.1.2 P2: helper defined as a nested local [let] inside another
   function's body. The body-introducer scanner must descend into the
   surrounding [Texp_let] (handled by [resolve_to_function]) to reach
   the helper. Expected: 0 findings AND body_introduces=["Bar"]. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let _use () =
  let raise_bar () : (int, [> `Bar ], 'r) Hamlet.t = failure `Bar in
  catch (prog ()) ~f:(function `Foo -> raise_bar ())
