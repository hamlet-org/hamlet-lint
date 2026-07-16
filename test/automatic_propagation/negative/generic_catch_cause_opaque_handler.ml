open Hamlet

let opaque_handler _cause =
  if Sys.opaque_identity true then Combinators.fail `Cause_recovered
  else Combinators.fail `Cause_residual

let[@hamlet.generic] recover_cause source =
  source
  |> Combinators.catch_cause ~handler:opaque_handler
  |> Combinators.catch ~handler:(function
    | `Cause_recovered -> Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
