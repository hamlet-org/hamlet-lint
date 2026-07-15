(** A catalogue leaf partitions one or more atoms under one nominal identity.
    Requirement leaves are always singleton. Error leaves may be grouped when a
    declared error alias owns several variant members. *)
type unmaterializable_reason =
  | Abstract_declaration
  | Hidden_alias
  | Missing_cases_catalogue
  | No_named_pattern
  | Grouped_requirement

type materialization =
  | Direct
  | Structural_variant
  | Error_cases of {
      catalogue : Identity.t;
      union : Identity.t;
      field : string;
    }
  | Requirement_tag
  | Unavailable of unmaterializable_reason

type t

type validation_error =
  | Empty_error_leaf
  | Wrong_member_kind of { expected : Kind.t; actual : Kind.t }
  | Duplicate_member of Atom.t
  | Invalid_materialization of {
      kind : Kind.t;
      materialization : materialization;
    }
  | Empty_cases_field

val error :
  identity:Identity.t ->
  members:Atom.t list ->
  materialization:materialization ->
  (t, validation_error) result

val requirement :
  identity:Identity.t ->
  member:Atom.t ->
  materialization:materialization ->
  (t, validation_error) result

val identity : t -> Identity.t
val kind : t -> Kind.t
val members : t -> Atom.t list
val materialization : t -> materialization
val is_grouped : t -> bool
val is_materializable : t -> bool
val compare : t -> t -> int
val equal : t -> t -> bool
