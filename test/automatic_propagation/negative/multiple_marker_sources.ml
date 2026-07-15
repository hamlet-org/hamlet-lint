open Hamlet

module Errors = struct
  type a = [ `A ]
  type b = [ `B ]
  type c = [ `C ]
  type all = [ a | b | c ]
end

let source : (unit, Errors.all, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`C : Errors.all)

let left =
  Hamlet.Combinators.catch source ~handler:(function
    | #Errors.a -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let right =
  Hamlet.Combinators.catch source ~handler:(function
    | #Errors.b -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let combined =
  let left = (left :> (unit, Errors.all, Hamlet.never) Hamlet.t) in
  let right = (right :> (unit, Errors.all, Hamlet.never) Hamlet.t) in
  Hamlet.Combinators.both left right
  |> Hamlet.Combinators.catch ~handler:(function
    | #Errors.c -> Hamlet.Combinators.return ((), ())
    | [%hamlet.propagate_e.auto] -> .)
