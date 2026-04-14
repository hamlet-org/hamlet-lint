(* Fixture: arm body uses [Combinators.try_catch] with an inline exn
   handler that returns a direct polymorphic-variant tag. Walker should
   recognise [try_catch _ (fun _ -> `Bar)] as introducing [`Bar]. *)

open Hamlet.Combinators

exception Boom

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let _use () =
  catch (prog ()) ~f:(function `Foo ->
      try_catch (fun () -> raise Boom) (fun _ -> `Bar))
