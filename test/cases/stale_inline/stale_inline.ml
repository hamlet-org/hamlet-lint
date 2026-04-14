(* End-to-end fixture. A [Combinators.catch] whose input effect has 'e lb
   = {`NotFound} but whose handler re-raises fresh `Timeout and `Forbidden
   tags: two phantoms, two findings expected. *)

open Hamlet.Combinators

let prog () : (int, [> `NotFound ], 'r) Hamlet.t = failure `NotFound

(* stale forwarding arms for `Timeout and `Forbidden *)
let stale () =
  catch (prog ()) ~f:(function
    | `NotFound -> success 0
    | `Timeout -> failure `Timeout
    | `Forbidden -> failure `Forbidden)
