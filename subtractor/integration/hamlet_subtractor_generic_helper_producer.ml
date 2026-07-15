let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.fail `Recovery
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_missing_to_unit source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) Hamlet.t
end]

let[@hamlet.generic] provide_logger logger source =
  Hamlet.Combinators.provide source ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)

module Ordinary = struct
  let add left right = left + right
  let identity value = value
end
