(** A compatibility comparison over two incomplete observations. This domain
    retains the historical list-set rule without claiming exact proof status. *)
type t

type validation_error =
  | Kind_mismatch of { declared : Kind.t; upstream : Kind.t }

val create :
  declared:Observation.t ->
  upstream:Observation.t ->
  (t, validation_error) result

val kind : t -> Kind.t
val declared : t -> Observation.t
val upstream : t -> Observation.t
val extra : t -> string list
