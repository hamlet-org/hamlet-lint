(** Incomplete tag-name evidence used by private Typedtree support. Observations
    preserve source order and cannot be promoted to exact subtraction proofs by
    this API. *)
type t

val of_tags : kind:Kind.t -> string list -> t
val kind : t -> Kind.t
val tags : t -> string list
val add_tags : t -> string list -> t
val subtract : t -> handled:string list -> t
val union : t -> t -> t option
val compare : t -> t -> int
val equal : t -> t -> bool
