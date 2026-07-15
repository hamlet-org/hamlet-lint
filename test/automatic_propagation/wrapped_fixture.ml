[%%hamlet.service
module type Remote = sig
  type first = [ `Wrapped_first ]
  type second = [ `Wrapped_second of string ]

  val run : unit -> (string, [> first | second ], 'r) Hamlet.t
end]
[@@rest_cross_cu]

let program : (string, Remote.Errors.error, Remote.Tag.r) Hamlet.t =
  Hamlet.Combinators.fail (`Wrapped_second "wrapped" : Remote.Errors.error)
