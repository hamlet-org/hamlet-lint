type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let case_generic_first =
  Hamlet_subtractor_generic_helper_producer.recover_missing first_source

let case_generic_second =
  Hamlet_subtractor_generic_helper_producer.recover_missing second_source

let generic_first_handled =
  Hamlet.Combinators.catch case_generic_first ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let generic_direct_inside_catch =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing first_source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let generic_direct_inside_chain =
  Hamlet.Combinators.chain
    (Hamlet_subtractor_generic_helper_producer.recover_missing second_source)
    ~handler:(fun () -> Hamlet.Combinators.return "done")

let ordinary_qualified_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.add 20 22

let ordinary_qualified_nested_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.identity
    (Hamlet_subtractor_generic_helper_producer.Ordinary.add 1 2)
