type propagation_kind = Error_propagation | Requirement_propagation

val generic_output_link_attribute : string
val layer_forwarding_attribute : string
val layer_type_attribute : string
val contributor_attribute : string

type marker = {
  id : string;
  original_id : string;
  kind : propagation_kind;
  loc : Ppxlib.Location.t;
}

type owner_form = Direct | Pipe

type owner = {
  marker : marker;
  form : owner_form;
  call_loc : Ppxlib.Location.t;
  upstream_loc : Ppxlib.Location.t;
  handler_loc : Ppxlib.Location.t;
}

type refusal_reason =
  | No_supported_owner
  | Named_handler
  | Ambiguous_owner
  | Unsupported_call_shape
  | Wrong_channel of { owner : propagation_kind; marker : propagation_kind }

type refusal = {
  marker : marker;
  reason : refusal_reason;
  loc : Ppxlib.Location.t;
}

type prepared = {
  base_structure : Ppxlib.Parsetree.structure;
  probe_structure : Ppxlib.Parsetree.structure;
      (** Compatibility alias for [probe_structure]. *)
  structure : Ppxlib.Parsetree.structure;
  markers : marker list;
  owners : owner list;
  refusals : refusal list;
}

(** Prepare syntactic owner candidates only. A later evidence phase must verify
    the typed callee path and UID before trusting an owner. *)
val prepare : Ppxlib.Parsetree.structure -> prepared

type variant_row = { labels : string list; closed : bool; fixed : bool }

type normalized_type =
  | Variable
  | Variant of variant_row
  | Constructor of string * normalized_type list
  | Other
      (** Debug and marker-linkage observations only. These shapes are not exact
          row proof evidence. *)

type typed_observation = {
  id : string;
  kind : propagation_kind;
  upstream_type : normalized_type;
  marker_type : normalized_type;
}

type lookup_error =
  | Missing_upstream of string
  | Missing_marker of string
  | Duplicate_upstream of string
  | Duplicate_marker of string
  | Invalid_marker_id of string

(** Return immutable observations for probe-owned upstream and marker nodes. *)
val observe_typedtree :
  Typedtree.structure -> (typed_observation list, lookup_error list) result
