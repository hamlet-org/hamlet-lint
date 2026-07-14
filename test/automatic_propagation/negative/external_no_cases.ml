open Hamlet

let result =
  No_cases_fixture.program
  |> Combinators.catch ~handler:(fun error ->
      match error with
      | #No_cases_fixture.Legacy.Errors.legacy_fallback ->
          Combinators.return "fallback"
      | [%hamlet.propagate_e.auto] -> .)
