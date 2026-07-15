let[@hamlet.generic] recover_other source =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_nested_inner_fixture.recover_missing source)
    ~handler:(function
    | `Other -> Hamlet.Combinators.success ()
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_both source =
  Hamlet_subtractor_nested_inner_fixture.recover_other
    (Hamlet_subtractor_nested_inner_fixture.recover_missing source)

let[@hamlet.generic] recover_missing_after_chain source =
  Hamlet.Combinators.chain
    (Hamlet_subtractor_nested_inner_fixture.recover_missing source)
    ~handler:(fun () -> Hamlet.Combinators.return ())

type source_errors = [ `Extra | `Missing | `Other ]

let source : (unit, source_errors, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail `Extra

let case_nested = recover_other source

let narrow : (unit, [ `Extra ], Hamlet.never) Hamlet.t = case_nested

let both_nested : (unit, [ `Extra ], Hamlet.never) Hamlet.t =
  recover_both source

let chained_nested : (unit, [ `Extra | `Other ], Hamlet.never) Hamlet.t =
  recover_missing_after_chain source
