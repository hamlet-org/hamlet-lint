(* v0.1.2 P2: helper defined as a top-level [let] in the same module,
   taking a parameter, and called from inside the [catch] arm body via
   a multi-argument application. Resolved via the per-module
   [local_env]. Expected: 0 findings AND body_introduces=["Bar"]. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let raise_bar_for (_n : int) : (int, [> `Bar ], 'r) Hamlet.t = failure `Bar

let _use () = catch (prog ()) ~f:(function `Foo -> raise_bar_for 42)
