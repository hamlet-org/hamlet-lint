open Hamlet

[%%hamlet.service
module type Remote = sig
  type connect_error = [ `Connect_error ]
  type read_error = [ `Read_error of string ]
  type write_error = [ `Write_error of int ]

  val run : unit -> (unit, [> connect_error | read_error | write_error ], 'r) t
end
[@@rest_cross_cu]]

let source choose : (unit, Remote.Errors.error, never) t =
  match choose with
  | 0 -> Combinators.fail `Connect_error
  | 1 -> Combinators.fail (`Read_error "read")
  | _ -> Combinators.fail (`Write_error 1)
