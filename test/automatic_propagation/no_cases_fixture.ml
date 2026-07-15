open Hamlet

let ( let* ) = Combinators.( let* )

[%%hamlet.service
module type Legacy = sig
  type legacy_error = [ `Legacy_error ]
  type legacy_fallback = [ `Legacy_fallback ]

  val fetch : unit -> (string, [> legacy_error | legacy_fallback ], 'r) t
end]

let program : (string, Legacy.Errors.error, Legacy.Tag.r) Hamlet.t =
  let* (module Legacy) = Legacy.Tag.summon in
  Legacy.fetch ()
