(** A normalized polymorphic-variant member. The declaration identity records
    where the row member was certified, while [label] and [payload] preserve
    runtime shape without relying on a printed compiler type. *)
type payload = No_payload | Payload of Type_identity.t

type t

type validation_error = Empty_label

val make :
  kind:Kind.t ->
  declaration:Identity.t ->
  label:string ->
  payload:payload ->
  (t, validation_error) result

val error :
  declaration:Identity.t ->
  label:string ->
  payload:payload ->
  (t, validation_error) result

val requirement :
  declaration:Identity.t ->
  label:string ->
  payload:payload ->
  (t, validation_error) result

val kind : t -> Kind.t
val declaration : t -> Identity.t
val label : t -> string
val payload : t -> payload
val payload_arity : t -> int
val compare : t -> t -> int
val equal : t -> t -> bool

(* Compare runtime variant shape while ignoring nominal declaration identity. *)
val compare_structural : t -> t -> int

val equal_structural : t -> t -> bool
val to_string : t -> string
