[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.fail `Recovery
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] provide_logger logger source =
  source
  |> Hamlet.Combinators.provide ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)

let[@hamlet.generic] alternating logger source =
  Hamlet.Combinators.provide
    (Hamlet.Combinators.catch source ~handler:(function
      | `Missing -> Hamlet.Combinators.fail `Recovery
      | [%hamlet.propagate_e.auto] -> .))
    ~handler:(function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)

let[@hamlet.generic] guarded enabled source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing when enabled -> Hamlet.Combinators.success ()
    | [%hamlet.propagate_e.auto] -> .)
