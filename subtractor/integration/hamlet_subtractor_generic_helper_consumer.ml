type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let case_generic_first =
  Hamlet_subtractor_generic_helper_producer.recover_missing first_source
    [%hamlet.forward.auto]

let case_generic_second =
  Hamlet_subtractor_generic_helper_producer.recover_missing second_source
    [%hamlet.forward.auto]

let generic_first_handled =
  Hamlet.Combinators.catch case_generic_first ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())
