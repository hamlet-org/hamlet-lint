(** Versioned normalized resolver request and response values. The wire contains
    only core values, context fingerprints, and one validated outcome per
    marker. *)
val version : int

type package_mode = Standalone | For_pack of string

type tool_context = {
  ocaml_version : string;
  hamlet_subtractor_version : string;
  resolver_version : string;
  catalogue_schema_version : int;
}

type compiler_flags = {
  debug : bool;
  principal : bool;
  recursive_types : bool;
  alias_dependencies : bool;
  use_threads : bool;
  unboxed_types : bool;
}

type ast_descriptor = {
  path : string;
  input_name : string;
  magic : string;
  digest : string;
  byte_length : int;
}

type probe_unit = Synthetic_unit of string

type request
type outcome = Resolved of Residual.t | Refused of Diagnostic.t
type marker_result
type catalogue
type response

type construction_error =
  | Outcome_marker_mismatch
  | Outcome_kind_mismatch of { marker : Kind.t; proof : Kind.t }
  | Missing_resolution_certificate
  | Unexpected_resolution_certificate
  | Resolution_certificate_mismatch
  | Empty_request_id
  | Empty_context_fingerprint
  | Empty_source_file
  | Empty_tool_name
  | Empty_ast_path
  | Relative_ast_path
  | Empty_ast_input_name
  | Empty_ast_magic
  | Empty_ast_digest
  | Invalid_ast_byte_length of int
  | Empty_synthetic_unit
  | Empty_tool_version of string
  | Invalid_catalogue_schema_version of int
  | Empty_for_pack
  | Duplicate_marker of Marker.id
  | Empty_catalogue of Identity.t
  | Empty_catalogue_field of Identity.t
  | Duplicate_catalogue_field_name of { catalogue : Identity.t; name : string }
  | Duplicate_catalogue_leaf of { catalogue : Identity.t; leaf : Identity.t }
  | Conflicting_catalogue of Identity.t

type decode_error =
  | Version_mismatch of { expected : int; actual : int }
  | Malformed of { path : string list; message : string }

type correlation_error =
  | Request_id_mismatch of { expected : string; actual : string }
  | Context_fingerprint_mismatch of { expected : string; actual : string }
  | Ast_digest_mismatch of { expected : string; actual : string }
  | Missing_marker_result of Marker.id
  | Unexpected_marker_result of Marker.id
  | Marker_mismatch of { expected : Marker.t; actual : Marker.t }

(** Normalized codecs shared by bounded metadata protocols. Decoders receive a
    JSON path so callers can preserve precise error locations. *)
val leaf_to_json : Leaf.t -> Yojson.Safe.t

val leaf_of_json : string list -> Yojson.Safe.t -> (Leaf.t, decode_error) result
val proof_to_json : Proof.t -> Yojson.Safe.t

val proof_of_json :
  string list -> Yojson.Safe.t -> (Proof.t, decode_error) result

val evidence_to_json : Effect_certificate.evidence -> Yojson.Safe.t

val evidence_of_json :
  string list ->
  Yojson.Safe.t ->
  (Effect_certificate.evidence, decode_error) result

val request :
  request_id:string ->
  source_file:string ->
  tool_name:string ->
  probe_ast:ast_descriptor ->
  probe_unit:probe_unit ->
  tool_context:tool_context ->
  context_fingerprint:string ->
  include_dirs:string list ->
  hidden_include_dirs:string list ->
  visible_paths:string list ->
  hidden_paths:string list ->
  opens:string list ->
  package_mode:package_mode ->
  compiler_flags:compiler_flags ->
  expected_markers:Marker.t list ->
  (request, construction_error) result

val request_id : request -> string
val source_file : request -> string
val tool_name : request -> string
val probe_ast : request -> ast_descriptor
val probe_unit : request -> probe_unit
val tool_context : request -> tool_context
val request_context_fingerprint : request -> string
val include_dirs : request -> string list
val hidden_include_dirs : request -> string list
val visible_paths : request -> string list
val hidden_paths : request -> string list
val opens : request -> string list
val package_mode : request -> package_mode
val compiler_flags : request -> compiler_flags
val expected_markers : request -> Marker.t list
val encode_request : request -> string
val decode_request : string -> (request, decode_error) result
val compare_request : request -> request -> int
val equal_request : request -> request -> bool

val marker_result :
  marker:Marker.t ->
  outcome:outcome ->
  certificate:Effect_certificate.t option ->
  (marker_result, construction_error) result

val marker : marker_result -> Marker.t
val outcome : marker_result -> outcome
val certificate : marker_result -> Effect_certificate.t option

val catalogue :
  identity:Identity.t ->
  union:Identity.t ->
  fields:(string * Identity.t) list ->
  (catalogue, construction_error) result

val catalogue_identity : catalogue -> Identity.t
val catalogue_union : catalogue -> Identity.t
val catalogue_fields : catalogue -> (string * Identity.t) list

val response :
  ?catalogues:catalogue list ->
  request_id:string ->
  context_fingerprint:string ->
  ast_digest:string ->
  marker_result list ->
  (response, construction_error) result

val response_request_id : response -> string
val context_fingerprint : response -> string
val response_ast_digest : response -> string
val results : response -> marker_result list
val catalogues : response -> catalogue list
val validate_response :
  request:request -> response:response -> (unit, correlation_error) result
val encode : response -> string
val decode : string -> (response, decode_error) result
val compare : response -> response -> int
val equal : response -> response -> bool
