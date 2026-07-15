let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.fail `Recovery
    | [%hamlet.propagate_e.auto] -> .)
