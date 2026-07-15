let[@hamlet.generic] recover_other source =
  Hamlet.Combinators.catch
    (Hamlet_subtractor_nested_inner_fixture.recover_missing source
       [%hamlet.forward.auto])
    ~handler:(function
      | `Other -> Hamlet.Combinators.success ()
      | [%hamlet.propagate_e.auto] -> .)

type source_errors = [ `Extra | `Missing | `Other ]

let source : (unit, source_errors, Hamlet.never) Hamlet.t = assert false
let case_nested = recover_other source [%hamlet.forward.auto]

let narrow : (unit, [ `Extra ], Hamlet.never) Hamlet.t = case_nested
