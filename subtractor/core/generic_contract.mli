(** Compiler-independent contracts for caller-specialized generic helpers. *)

val schema_version : int
val max_encoded_bytes : int
val max_slots : int
val max_expression_depth : int
val max_expression_nodes : int
val max_leaves : int

type channel_expression

type expression_view =
  | Input of Kind.t
  | Evidence of { kind : Kind.t; evidence : Effect_certificate.evidence }
  | Union of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      terms : channel_expression list;
    }
  | Subtract of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      source : channel_expression;
      handled : Leaf.t list;
      explicitly_forwarded : Leaf.t list;
      recovery : channel_expression;
    }

type expression_error =
  | Empty_union
  | Wrong_expression_kind of { expected : Kind.t; actual : Kind.t }
  | Wrong_leaf_kind of { leaf : Identity.t; expected : Kind.t; actual : Kind.t }
  | Duplicate_leaf of Identity.t
  | Conflicting_partition_leaf of Identity.t
  | Partition_leaf_not_claimed of Identity.t

val input : Kind.t -> channel_expression
val exact : Proof.t -> channel_expression
val opaque : Kind.t -> Effect_certificate.opacity list -> channel_expression

val union :
  kind:Kind.t ->
  operation:Proof.composition ->
  inputs:Marker.id list ->
  channel_expression list ->
  (channel_expression, expression_error) result

val subtract :
  operation:Proof.composition ->
  inputs:Marker.id list ->
  source:channel_expression ->
  handled:Leaf.t list ->
  explicitly_forwarded:Leaf.t list ->
  recovery:channel_expression ->
  (channel_expression, expression_error) result

val clear : Kind.t -> channel_expression
val expression_kind : channel_expression -> Kind.t
val expression_view : channel_expression -> expression_view
val compare_expression : channel_expression -> channel_expression -> int
val equal_expression : channel_expression -> channel_expression -> bool

type symbolic_certificate

val certificate :
  errors:channel_expression ->
  requirements:channel_expression ->
  (symbolic_certificate, expression_error) result

val input_certificate : symbolic_certificate
val concrete : Effect_certificate.t -> symbolic_certificate
val errors : symbolic_certificate -> channel_expression
val requirements : symbolic_certificate -> channel_expression

val chain :
  inputs:Marker.id list ->
  symbolic_certificate list ->
  (symbolic_certificate, expression_error) result

val catch :
  inputs:Marker.id list ->
  source:symbolic_certificate ->
  handled:Leaf.t list ->
  explicitly_forwarded:Leaf.t list ->
  recoveries:symbolic_certificate list ->
  (symbolic_certificate, expression_error) result

val provide :
  inputs:Marker.id list ->
  source:symbolic_certificate ->
  handled:Leaf.t list ->
  explicitly_forwarded:Leaf.t list ->
  handlers:symbolic_certificate list ->
  (symbolic_certificate, expression_error) result

val with_errors :
  source:symbolic_certificate ->
  errors:channel_expression ->
  (symbolic_certificate, expression_error) result

val with_requirements :
  source:symbolic_certificate ->
  requirements:channel_expression ->
  (symbolic_certificate, expression_error) result

val substitute_expression :
  input:symbolic_certificate -> channel_expression -> channel_expression

val substitute :
  input:symbolic_certificate -> symbolic_certificate -> symbolic_certificate

type slot_id = private string
type slot

type slot_error =
  | Empty_slot_id
  | Slot_id_has_surrounding_whitespace
  | Negative_slot_ordinal of int
  | Slot_expression_error of expression_error

val slot_id : string -> (slot_id, slot_error) result
val slot_id_to_string : slot_id -> string

val namespace_slot_id :
  namespace:string -> slot_id -> (slot_id, slot_error) result

val slot_belongs_to_namespace : namespace:string -> slot_id -> bool

val slot :
  id:slot_id ->
  ordinal:int ->
  kind:Kind.t ->
  input:channel_expression ->
  claimed:Leaf.t list ->
  handled:Leaf.t list ->
  explicitly_forwarded:Leaf.t list ->
  recovery:channel_expression ->
  (slot, slot_error) result

val slot_id_value : slot -> slot_id
val slot_ordinal : slot -> int
val slot_kind : slot -> Kind.t
val slot_input : slot -> channel_expression
val slot_claimed : slot -> Leaf.t list
val slot_handled : slot -> Leaf.t list
val slot_explicitly_forwarded : slot -> Leaf.t list
val slot_recovery : slot -> channel_expression
val compare_slot : slot -> slot -> int
val equal_slot : slot -> slot -> bool

type t

type validation_error =
  | Empty_helper_fingerprint
  | Helper_fingerprint_has_surrounding_whitespace
  | Empty_definition_context
  | Definition_context_has_surrounding_whitespace
  | Negative_effect_parameter of int
  | Duplicate_slot_id of slot_id
  | Duplicate_slot_ordinal of int
  | Too_many_slots of { limit : int; actual : int }
  | Expression_too_deep of { limit : int; actual : int }
  | Too_many_expression_nodes of { limit : int; actual : int }
  | Too_many_leaves of { limit : int; actual : int }
  | Invalid_expression of expression_error

val create :
  helper_fingerprint:string ->
  definition_context:string ->
  effect_parameter:int ->
  slots:slot list ->
  output:symbolic_certificate ->
  (t, validation_error) result

val helper_fingerprint : t -> string
val definition_context : t -> string
val effect_parameter : t -> int
val slots : t -> slot list
val output : t -> symbolic_certificate
val compare : t -> t -> int
val equal : t -> t -> bool

type rebase_error =
  | Invalid_rebase_target of Identity.validation_error
  | Invalid_rebased_contract of validation_error

(** Relocate identities created in the helper's definition context to the
    installed compilation-unit identity. Identities originating elsewhere are
    preserved. *)
val rebase :
  module_prefix:string list ->
  interface_digest:string ->
  t ->
  (t, rebase_error) result

type evaluation_error =
  | Opaque_expression of {
      kind : Kind.t;
      reasons : Effect_certificate.opacity list;
    }
  | Certificate_error of Effect_certificate.validation_error
  | Residual_error of Diagnostic.code
  | Evaluated_wrong_kind of { expected : Kind.t; actual : Kind.t }

val evaluate_expression :
  input:Effect_certificate.t ->
  channel_expression ->
  (Effect_certificate.evidence, evaluation_error) result

val evaluate :
  input:Effect_certificate.t ->
  symbolic_certificate ->
  (Effect_certificate.t, evaluation_error) result

type instantiated_slot

val instantiate_slot :
  input:Effect_certificate.t ->
  slot ->
  (instantiated_slot, evaluation_error) result

val instantiate_slots :
  input:Effect_certificate.t ->
  t ->
  (instantiated_slot list, evaluation_error) result

val instantiated_slot : instantiated_slot -> slot
val instantiated_residual : instantiated_slot -> Residual.t

type serialization_error =
  | Encoded_contract_too_large of { limit : int; actual : int }

type decode_error =
  | Decode_contract_too_large of { limit : int; actual : int }
  | Malformed_json of string
  | Malformed_contract of { path : string list; message : string }
  | Schema_version_mismatch of { expected : int; actual : int }
  | Invalid_contract of validation_error

val encode : t -> (string, serialization_error) result
val decode : string -> (t, decode_error) result
val digest : t -> (string, serialization_error) result
