(** The propagation channel owned by a marker, proof, or observation. *)
type t = Error | Requirement

val compare : t -> t -> int
val equal : t -> t -> bool
val to_string : t -> string
val explicit_fallback : t -> string
