(* Fixture: the handler is reached through a shape the walker cannot chase
   through a [Texp_function] — here a [Lazy.force] application. Equivalent
   from the walker's point of view to an [Ext.h] reference where [Ext] is
   not in the cmt load set: [resolve_to_function] fails, the site is
   silently skipped, and the run exits clean.

   Also verifies that [HAMLET_LINT_DEBUG=1] emits a diagnostic on stderr. *)

open Hamlet.Combinators

let key : (_, string) Hamlet.Service.key = Hamlet.Service.make "ur_svc"

let prog () : (string, 'e, [> `Console ]) Hamlet.t = summon key `Console

let mk_h () =
  Lazy.force
    (lazy (function `Console -> give key "impl" | `Logger -> need `Logger))

(* Expected: walker cannot chase [mk_h ()] through [Lazy.force (...)], falls
   back to the skip path. No finding emitted. *)
let quiet () = provide (mk_h ()) (prog ())
