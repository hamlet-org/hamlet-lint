module Core = Hamlet_subtractor_core

type lookup_failure =
  | Missing_probe_node of { marker_id : string; attribute : string }
  | Duplicate_probe_node of { marker_id : string; attribute : string }
  | Invalid_marker_id of string

type refusal_reason =
  | Lookup_failure of lookup_failure
  | Fake_or_aliased_callee
  | Wrong_hamlet_effect_shape
  | Abstract_or_hidden_alias of Core.Identity.t option
  | Open_row
  | Unresolved_row
  | Polymorphic_parameter
  | Unsupported_payload of Core.Diagnostic.payload_shape
  | Invalid_error_catalogue of string
  | Grouped_requirement of Core.Identity.t
  | Unsupported_pattern
  | Unsupported_handler_rhs
  | Higher_order_flow
  | Opaque_origin
  | Residual_refusal of Core.Diagnostic.code
  | Core_validation_failed of string

type refusal = { marker : Core.Marker.t; reason : refusal_reason }

type resolved = {
  marker : Core.Marker.t;
  input : Core.Proof.t;
  certificate : Core.Effect_certificate.t;
  residual : Core.Residual.t;
  arms : Core.Residual.arm list;
  catalogues : Hamlet_subtractor_catalogue.t list;
}

type outcome = Resolved of resolved | Refused of refusal

val refusal_message : refusal -> string

(** Resolve immutable proof evidence while the probe Typedtree and typing
    environment are still alive. No compiler-owned value occurs in [outcome]. *)
val resolve_typedtree :
  context_digest:string -> Typedtree.structure -> outcome list

(** Run the deterministic compiler-free engine while Typedtree evidence is live,
    retaining exact certificates for dependent markers. *)
val elaborate_typedtree :
  ?generic_outputs:
    (string * Core.Effect_certificate.t * Hamlet_subtractor_catalogue.t list)
    list ->
  context_digest:string ->
  Typedtree.structure ->
  (Hamlet_subtractor_engine.t, refusal) result

type generic_definition = {
  attachment_id : string;
  helper : string;
  contract : Core.Generic_contract.t;
  catalogues : Hamlet_subtractor_catalogue.t list;
}

type generic_call =
  | Ignored_generic_call of { attachment_id : string }
  | Resolved_generic_call of {
      attachment_id : string;
      marker_links : string list;
      contract : Core.Generic_contract.t;
      input : Core.Effect_certificate.t;
      output : Core.Effect_certificate.t;
      catalogues : Hamlet_subtractor_catalogue.t list;
      location : Location.t;
    }

type generic_refusal = { location : Location.t; reason : refusal_reason }

val generic_refusal_message : generic_refusal -> string

(** Convert rewritten generic-helper definitions into immutable symbolic
    contracts while their Typedtree identities are available. *)
val generic_definitions_typedtree :
  context_digest:string ->
  Typedtree.structure ->
  (generic_definition list, generic_refusal) result

val generic_calls_typedtree :
  context_digest:string ->
  definitions:generic_definition list ->
  Typedtree.structure ->
  (generic_call list, generic_refusal) result

(** Follow a typed generic source from its effect parameter through verified
    Hamlet primitives. Earlier generic marker outputs are supplied by their
    stable owner IDs. The result contains no compiler-owned values. *)
val symbolic_source_certificate :
  context_digest:string ->
  marker_id:string ->
  kind:Core.Kind.t ->
  input_uid:Shape.Uid.t ->
  dependencies:(string * Core.Generic_contract.symbolic_certificate) list ->
  Typedtree.structure ->
  Typedtree.expression ->
  ( Core.Generic_contract.symbolic_certificate
    * Hamlet_subtractor_catalogue.t list,
    refusal_reason )
  result
