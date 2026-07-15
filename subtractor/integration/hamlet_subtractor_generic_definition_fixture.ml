[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) Hamlet.t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) Hamlet.t
end]

let logger_requirement : (unit, Hamlet.never, Logger.Tag.r) Hamlet.t =
  let open Hamlet.Combinators in
  let* _logger = Logger.Tag.summon in
  return ()

let requirements : (unit, Hamlet.never, [ Logger.Tag.r | Clock.Tag.r ]) Hamlet.t
    =
  let open Hamlet.Combinators in
  let* _logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  return ()

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

type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let first_specialization = recover_missing first_source [%hamlet.forward.auto]

let second_specialization = recover_missing second_source [%hamlet.forward.auto]

let first_handled =
  Hamlet.Combinators.catch first_specialization ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())
