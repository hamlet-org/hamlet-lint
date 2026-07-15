type first_errors = [ `Missing | `Timeout ]
type second_errors = [ `Missing | `Offline ]
type third_errors = [ `Missing | `Offline | `Timeout ]

let first_source : (unit, first_errors, Hamlet.never) Hamlet.t = assert false

let inferred_first_source =
  if Sys.opaque_identity true then Hamlet.Combinators.fail `Missing
  else Hamlet.Combinators.fail `Timeout

let second_source : (unit, second_errors, Hamlet.never) Hamlet.t = assert false

let third_source : (unit, third_errors, Hamlet.never) Hamlet.t = assert false

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
    (Hamlet_subtractor_generic_helper_producer.recover_missing
       inferred_first_source) ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | `Timeout -> Hamlet.Combinators.return ())

let generic_direct_inside_chain =
  Hamlet.Combinators.chain
    (Hamlet_subtractor_generic_helper_producer.recover_missing second_source)
    ~handler:(fun () -> Hamlet.Combinators.return "done")

let generic_output_to_error_marker : (unit, [ `Timeout ], Hamlet.never) Hamlet.t
    =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing first_source)
    ~handler:(function
    | `Recovery -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let generic_output_feeds_following_marker :
    (unit, [ `Timeout ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_generic_helper_producer.recover_missing_to_unit
       third_source) ~handler:(function
    | `Offline -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let ordinary_qualified_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.add 20 22

let ordinary_qualified_nested_call =
  Hamlet_subtractor_generic_helper_producer.Ordinary.identity
    (Hamlet_subtractor_generic_helper_producer.Ordinary.add 1 2)
