(* Helper module: defines [raise_bar] which calls [failure `Bar].
   The body-introducer scanner in another module's [catch] must
   resolve [Helpers.raise_bar] via the global cross-module env and
   recurse into its body. *)

open Hamlet.Combinators

let raise_bar () : (int, [> `Bar ], 'r) Hamlet.t = failure `Bar
