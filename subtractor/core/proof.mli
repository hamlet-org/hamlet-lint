(** Exact finite input evidence. There is deliberately no conversion from
    {!Observation.t}. Callers may create a proof only after a compiler adapter
    has established row closure, payload identity, provenance, and a unique
    catalogue partition. *)
type composition = Return | Fail | Summon | Chain | Map | Catch | Provide

type origin =
  | Closed_row
  | Generalized_value of Identity.t
  | External_value of Identity.t
  | Composition of { operation : composition; inputs : Marker.id list }

type t

type validation_error =
  | Wrong_leaf_kind of { leaf : Identity.t; expected : Kind.t; actual : Kind.t }
  | Duplicate_leaf_identity of Identity.t
  | Overlapping_atom of {
      atom : Atom.t;
      first_leaf : Identity.t;
      second_leaf : Identity.t;
    }

val create :
  kind:Kind.t ->
  origin:origin ->
  leaves:Leaf.t list ->
  (t, validation_error) result

val kind : t -> Kind.t
val origin : t -> origin
val leaves : t -> Leaf.t list
val atoms : t -> Atom.t list
val find_leaf : t -> Identity.t -> Leaf.t option
val compare : t -> t -> int
val equal : t -> t -> bool
