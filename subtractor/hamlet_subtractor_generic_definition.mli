type refusal_reason =
  | Invalid_annotation_payload
  | Duplicate_annotation
  | Recursive_binding
  | Anonymous_binding
  | Not_a_function
  | Missing_source_parameter
  | Unsupported_source_parameter
  | No_automatic_markers
  | Source_not_linear of int
  | Unsupported_source_flow
  | Marker_without_supported_owner
  | Wrong_marker_channel
  | Unsupported_handler
  | Multiple_symbolic_inputs of string list
  | Duplicate_helper of string
  | Companion_collision of string
  | Contract_encoding_failed of string

type refusal = { loc : Ppxlib.Location.t; reason : refusal_reason }

val refusal_message : refusal_reason -> string

val helper_attribute : string
val owner_attribute : string
val callee_attribute : string
val upstream_attribute : string
val handler_attribute : string
val slot_attribute : string

val strip_linkage_attributes :
  Ppxlib.Parsetree.structure -> Ppxlib.Parsetree.structure

val rewrite :
  Ppxlib.Parsetree.structure -> (Ppxlib.Parsetree.structure, refusal) result

val rewrite_exn : Ppxlib.Parsetree.structure -> Ppxlib.Parsetree.structure
