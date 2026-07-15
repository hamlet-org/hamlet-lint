(** The payload type algebra accepted by exact proofs. Compiler-specific type
    expressions must normalize into one of these constructors. Functions,
    objects, unresolved variables, open variants, and other shapes are
    intentionally absent and must produce a refusal before proof creation. *)
type primitive =
  | Unit
  | Bool
  | Char
  | Int
  | Int32
  | Int64
  | Nativeint
  | Float
  | String
  | Bytes

type t

type view =
  | Primitive of primitive
  | Tuple of t list
  | Nominal of { declaration : Identity.t; arguments : t list }

type validation_error = Tuple_requires_two_elements

val primitive : primitive -> t
val tuple : t list -> (t, validation_error) result
val nominal : declaration:Identity.t -> arguments:t list -> t
val view : t -> view
val compare : t -> t -> int
val equal : t -> t -> bool
val to_string : t -> string
