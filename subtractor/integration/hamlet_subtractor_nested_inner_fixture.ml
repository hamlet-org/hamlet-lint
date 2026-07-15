let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.success ()
    | [%hamlet.propagate_e.auto] -> .)
