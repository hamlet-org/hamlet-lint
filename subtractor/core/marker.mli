(** Stable marker identity assigned from the live source and transformation
    context. The core validates identity shape but does not prescribe the hash
    algorithm used by the PPX. *)
type id = private string

type t

type id_error = Empty_id | Surrounding_whitespace

val id_of_string : string -> (id, id_error) result
val id_to_string : id -> string
val compare_id : id -> id -> int

val make : id:id -> kind:Kind.t -> span:Source_span.t -> t
val id : t -> id
val kind : t -> Kind.t
val span : t -> Source_span.t
val compare : t -> t -> int
val equal : t -> t -> bool
