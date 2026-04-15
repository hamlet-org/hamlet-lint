(* Fixture: an arm body calls [failure `Bar] directly. The walker's
   body-introducer scanner recognises the direct [Combinators.failure]
   shape and records [`Bar] in the arm's [body_introduces]. No finding
   is expected.

   Pre-v0.1.1 walker: body_introduces=[] on every arm, but the rule only
   reports when an arm's pattern tag = a grown tag, and here no arm
   pattern matches `Bar, so v0.1.0 was already silent. This fixture
   therefore primarily verifies the extractor populates body_introduces
   correctly; the ND-JSON contract is sampled by the e2e test. *)

open Hamlet.Combinators

let prog () : (int, [> `Foo ], 'r) Hamlet.t = failure `Foo

let _use () = catch (prog ()) ~f:(function `Foo -> failure `Bar)
