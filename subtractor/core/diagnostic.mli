(** Structured refusal reasons shared by the PPX, resolver, and reporting tools.
    Messages are derived from these values and never contain compiler
    type-expression dumps. *)
type payload_shape =
  | Function
  | Object
  | Unresolved_variable
  | Open_variant
  | Package
  | Unsupported_structural_type

type code =
  | Open_row
  | Abstract_alias of Identity.t option
  | Unresolved_row
  | Polymorphic_parameter
  | Opaque_origin
  | Higher_order_flow
  | Invalid_owner
  | Invalid_error_catalogue of string
  | Unsupported_pattern
  | Unsupported_handler_rhs
  | Ambiguous_handler
  | Recursive_dependency of Marker.id list
  | Unsupported_payload of {
      declaration : Identity.t option;
      shape : payload_shape;
    }
  | Leaf_outside_universe of Identity.t
  | Atoms_outside_universe of Atom.t list
  | Partially_handled_group of { leaf : Leaf.t; matched : Atom.t list }
  | Unmaterializable_leaf of Leaf.t
  | Grouped_requirement of Identity.t
  | Duplicate_unguarded_arm of Identity.t
  | Conflicting_recovery_leaf of Identity.t
  | Wrong_channel of { expected : Kind.t; actual : Kind.t }

type t

val make : marker:Marker.t -> code:code -> t
val marker : t -> Marker.t
val code : t -> code
val fallback : t -> string
val message : t -> string
val compare : t -> t -> int
val equal : t -> t -> bool
