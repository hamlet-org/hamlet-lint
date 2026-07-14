(** Nominal declaration identity. The interface digest must identify the
    declaration view used to normalize the proof. Current-unit declarations use
    the digest of the transformed source and compilation context. *)
type t

type validation_error =
  | Empty_module_path
  | Empty_module_segment of int
  | Dotted_module_segment of { index : int; segment : string }
  | Empty_declaration_name
  | Empty_interface_digest

val make :
  module_path:string list ->
  declaration_name:string ->
  interface_digest:string ->
  (t, validation_error) result

val module_path : t -> string list
val declaration_name : t -> string
val interface_digest : t -> string
val compare : t -> t -> int
val equal : t -> t -> bool
val to_string : t -> string
