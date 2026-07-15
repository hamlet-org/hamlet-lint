let version = 5
let max_generic_attachment_payload_bytes = 1_048_576

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

type generic_attachment_kind = Definition | Call
type generic_expectation = { id : string; kind : generic_attachment_kind }

type generic_attachment = {
  id : string;
  kind : generic_attachment_kind;
  payload : string;
}

type request = {
  request_id : string;
  source_file : string;
  tool_name : string;
  probe_ast : ast_descriptor;
  probe_unit : probe_unit;
  tool_context : tool_context;
  context_fingerprint : string;
  include_dirs : string list;
  hidden_include_dirs : string list;
  visible_paths : string list;
  hidden_paths : string list;
  opens : string list;
  package_mode : package_mode;
  compiler_flags : compiler_flags;
  expected_markers : Marker.t list;
  generic_expectations : generic_expectation list;
}

type outcome = Resolved of Residual.t | Refused of Diagnostic.t
type marker_result = {
  marker : Marker.t;
  outcome : outcome;
  certificate : Effect_certificate.t option;
}

type catalogue = {
  identity : Identity.t;
  union : Identity.t;
  fields : (string * Identity.t) list;
}

type response = {
  request_id : string;
  context_fingerprint : string;
  ast_digest : string;
  results : marker_result list;
  catalogues : catalogue list;
  generic_attachments : generic_attachment list;
}

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
  | Empty_generic_attachment_id
  | Empty_generic_attachment_payload of string
  | Generic_attachment_payload_too_large of {
      id : string;
      limit : int;
      actual : int;
    }
  | Duplicate_generic_expectation of string
  | Duplicate_generic_attachment of string

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
  | Missing_generic_attachment of string
  | Unexpected_generic_attachment of string
  | Generic_attachment_kind_mismatch of {
      id : string;
      expected : generic_attachment_kind;
      actual : generic_attachment_kind;
    }

let marker_order first second =
  Marker.compare_id (Marker.id first) (Marker.id second)

let normalize_markers markers = List.sort marker_order markers

let duplicate_marker markers =
  let rec loop = function
    | first :: second :: _
      when Marker.compare_id (Marker.id first) (Marker.id second) = 0 ->
        Some (Marker.id first)
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop markers

let generic_expectation ~id ~kind =
  if String.trim id = "" then Error Empty_generic_attachment_id
  else Ok { id; kind }

let generic_expectation_id (expectation : generic_expectation) = expectation.id

let generic_expectation_kind (expectation : generic_expectation) =
  expectation.kind

let generic_attachment ~id ~kind ~payload =
  let actual = String.length payload in
  if String.trim id = "" then Error Empty_generic_attachment_id
  else if String.equal payload "" then
    Error (Empty_generic_attachment_payload id)
  else if actual > max_generic_attachment_payload_bytes then
    Error
      (Generic_attachment_payload_too_large
         { id; limit = max_generic_attachment_payload_bytes; actual })
  else Ok { id; kind; payload }

let generic_attachment_id (attachment : generic_attachment) = attachment.id
let generic_attachment_kind (attachment : generic_attachment) = attachment.kind
let generic_attachment_payload (attachment : generic_attachment) =
  attachment.payload

let generic_expectation_order
    (first : generic_expectation)
    (second : generic_expectation) =
  String.compare first.id second.id

let generic_attachment_order
    (first : generic_attachment)
    (second : generic_attachment) =
  String.compare first.id second.id

let duplicate_generic_expectation_id (items : generic_expectation list) =
  let rec loop (values : generic_expectation list) =
    match values with
    | first :: second :: _ when String.equal first.id second.id -> Some first.id
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop items

let normalize_generic_expectations expectations =
  let expectations = List.sort generic_expectation_order expectations in
  match duplicate_generic_expectation_id expectations with
  | Some id -> Error (Duplicate_generic_expectation id)
  | None -> Ok expectations

let duplicate_generic_attachment_id (items : generic_attachment list) =
  let rec loop (values : generic_attachment list) =
    match values with
    | first :: second :: _ when String.equal first.id second.id -> Some first.id
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop items

let normalize_generic_attachments attachments =
  let attachments = List.sort generic_attachment_order attachments in
  match duplicate_generic_attachment_id attachments with
  | Some id -> Error (Duplicate_generic_attachment id)
  | None -> Ok attachments

let validate_tool_context context =
  if String.trim context.ocaml_version = "" then
    Error (Empty_tool_version "ocaml_version")
  else if String.trim context.hamlet_subtractor_version = "" then
    Error (Empty_tool_version "hamlet_subtractor_version")
  else if String.trim context.resolver_version = "" then
    Error (Empty_tool_version "resolver_version")
  else if context.catalogue_schema_version < 1 then
    Error (Invalid_catalogue_schema_version context.catalogue_schema_version)
  else Ok ()

let request_with_generic_expectations
    ~generic_expectations
    ~request_id
    ~source_file
    ~tool_name
    ~probe_ast
    ~probe_unit
    ~tool_context
    ~context_fingerprint
    ~include_dirs
    ~hidden_include_dirs
    ~visible_paths
    ~hidden_paths
    ~opens
    ~package_mode
    ~compiler_flags
    ~expected_markers =
  if String.trim request_id = "" then Error Empty_request_id
  else if String.trim source_file = "" then Error Empty_source_file
  else if String.trim tool_name = "" then Error Empty_tool_name
  else if String.trim probe_ast.path = "" then Error Empty_ast_path
  else if Filename.is_relative probe_ast.path then Error Relative_ast_path
  else if String.trim probe_ast.input_name = "" then Error Empty_ast_input_name
  else if String.trim probe_ast.magic = "" then Error Empty_ast_magic
  else if String.trim probe_ast.digest = "" then Error Empty_ast_digest
  else if probe_ast.byte_length <= 0 then
    Error (Invalid_ast_byte_length probe_ast.byte_length)
  else if String.trim context_fingerprint = "" then
    Error Empty_context_fingerprint
  else
    match validate_tool_context tool_context with
    | Error _ as error -> error
    | Ok () -> (
        match probe_unit with
        | Synthetic_unit name when String.trim name = "" ->
            Error Empty_synthetic_unit
        | Synthetic_unit _ -> (
            match package_mode with
            | For_pack value when String.trim value = "" -> Error Empty_for_pack
            | _ -> (
                let expected_markers = normalize_markers expected_markers in
                match duplicate_marker expected_markers with
                | Some marker -> Error (Duplicate_marker marker)
                | None -> (
                    match
                      normalize_generic_expectations generic_expectations
                    with
                    | Error _ as error -> error
                    | Ok generic_expectations ->
                        Ok
                          {
                            request_id;
                            source_file;
                            tool_name;
                            probe_ast;
                            probe_unit;
                            tool_context;
                            context_fingerprint;
                            include_dirs;
                            hidden_include_dirs;
                            visible_paths;
                            hidden_paths;
                            opens;
                            package_mode;
                            compiler_flags;
                            expected_markers;
                            generic_expectations;
                          }))))

let request
    ~request_id
    ~source_file
    ~tool_name
    ~probe_ast
    ~probe_unit
    ~tool_context
    ~context_fingerprint
    ~include_dirs
    ~hidden_include_dirs
    ~visible_paths
    ~hidden_paths
    ~opens
    ~package_mode
    ~compiler_flags
    ~expected_markers =
  request_with_generic_expectations ~generic_expectations:[] ~request_id
    ~source_file ~tool_name ~probe_ast ~probe_unit ~tool_context
    ~context_fingerprint ~include_dirs ~hidden_include_dirs ~visible_paths
    ~hidden_paths ~opens ~package_mode ~compiler_flags ~expected_markers

let request_id (request : request) = request.request_id
let source_file (request : request) = request.source_file
let tool_name (request : request) = request.tool_name
let probe_ast (request : request) = request.probe_ast
let probe_unit (request : request) = request.probe_unit
let tool_context (request : request) = request.tool_context

let request_context_fingerprint (request : request) =
  request.context_fingerprint

let include_dirs (request : request) = request.include_dirs
let hidden_include_dirs (request : request) = request.hidden_include_dirs
let visible_paths (request : request) = request.visible_paths
let hidden_paths (request : request) = request.hidden_paths
let opens (request : request) = request.opens
let package_mode (request : request) = request.package_mode
let compiler_flags (request : request) = request.compiler_flags
let expected_markers (request : request) = request.expected_markers
let generic_expectations (request : request) = request.generic_expectations
let compare_request = Stdlib.compare
let equal_request first second = compare_request first second = 0

let same_leaf_set left right =
  let normalize = List.sort_uniq Leaf.compare in
  let left = normalize left and right = normalize right in
  List.length left = List.length right && List.for_all2 Leaf.equal left right

let certificate_matches residual certificate =
  let target =
    match Residual.kind residual with
    | Kind.Error -> Effect_certificate.errors certificate
    | Kind.Requirement -> Effect_certificate.requirements certificate
  in
  match Effect_certificate.evidence_view target with
  | Effect_certificate.Opaque_reasons _ -> true
  | Effect_certificate.Exact_proof proof ->
      Kind.equal (Proof.kind proof) (Residual.kind residual)
      && same_leaf_set (Proof.leaves proof) (Residual.output residual)

let marker_result ~marker ~outcome ~certificate =
  match outcome with
  | Resolved calculation ->
      let marker_kind = Marker.kind marker in
      let proof_kind = Residual.kind calculation in
      if not (Kind.equal marker_kind proof_kind) then
        Error
          (Outcome_kind_mismatch { marker = marker_kind; proof = proof_kind })
      else
        begin match certificate with
        | None -> Error Missing_resolution_certificate
        | Some certificate when certificate_matches calculation certificate ->
            Ok { marker; outcome; certificate = Some certificate }
        | Some _ -> Error Resolution_certificate_mismatch
        end
  | Refused diagnostic ->
      if Option.is_some certificate then Error Unexpected_resolution_certificate
      else if Marker.equal marker (Diagnostic.marker diagnostic) then
        Ok { marker; outcome; certificate = None }
      else Error Outcome_marker_mismatch

let marker result = result.marker
let outcome result = result.outcome
let certificate result = result.certificate

let catalogue ~identity ~union ~fields =
  let rec validate names leaves = function
    | [] -> Ok { identity; union; fields }
    | (name, leaf) :: rest ->
        if String.trim name = "" then Error (Empty_catalogue_field leaf)
        else if List.exists (String.equal name) names then
          Error (Duplicate_catalogue_field_name { catalogue = identity; name })
        else if List.exists (Identity.equal leaf) leaves then
          Error (Duplicate_catalogue_leaf { catalogue = identity; leaf })
        else validate (name :: names) (leaf :: leaves) rest
  in
  match fields with
  | [] -> Error (Empty_catalogue identity)
  | _ -> validate [] [] fields

let catalogue_identity catalogue = catalogue.identity
let catalogue_union catalogue = catalogue.union
let catalogue_fields catalogue = catalogue.fields

let sort_results results =
  List.sort
    (fun first second ->
      Marker.compare_id (Marker.id first.marker) (Marker.id second.marker))
    results

let find_duplicate results =
  let rec loop = function
    | first :: second :: _
      when Marker.compare_id (Marker.id first.marker) (Marker.id second.marker)
           = 0 ->
        Some (Marker.id first.marker)
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop results

let catalogue_order left right = Identity.compare left.identity right.identity

let normalize_catalogues catalogues =
  let catalogues = List.sort catalogue_order catalogues in
  let rec loop normalized = function
    | [] -> Ok (List.rev normalized)
    | [ catalogue ] -> Ok (List.rev (catalogue :: normalized))
    | first :: (second :: _ as tail) ->
        if not (Identity.equal first.identity second.identity) then
          loop (first :: normalized) tail
        else if Stdlib.compare first second = 0 then loop normalized tail
        else Error (Conflicting_catalogue first.identity)
  in
  loop [] catalogues

let response
    ?(catalogues = [])
    ?(generic_attachments = [])
    ~request_id
    ~context_fingerprint
    ~ast_digest
    results =
  if String.trim request_id = "" then Error Empty_request_id
  else if String.trim context_fingerprint = "" then
    Error Empty_context_fingerprint
  else if String.trim ast_digest = "" then Error Empty_ast_digest
  else
    let results = sort_results results in
    match find_duplicate results with
    | Some marker -> Error (Duplicate_marker marker)
    | None -> (
        match normalize_catalogues catalogues with
        | Error _ as error -> error
        | Ok catalogues -> (
            match normalize_generic_attachments generic_attachments with
            | Error _ as error -> error
            | Ok generic_attachments ->
                Ok
                  {
                    request_id;
                    context_fingerprint;
                    ast_digest;
                    results;
                    catalogues;
                    generic_attachments;
                  }))

let response_request_id (response : response) = response.request_id
let context_fingerprint (response : response) = response.context_fingerprint
let response_ast_digest (response : response) = response.ast_digest
let results (response : response) = response.results
let catalogues (response : response) = response.catalogues
let generic_attachments (response : response) = response.generic_attachments

let validate_generic_attachments
    (expected : generic_expectation list)
    (actual : generic_attachment list) =
  let rec loop
      (expected : generic_expectation list)
      (actual : generic_attachment list) =
    match (expected, actual) with
    | [], [] -> Ok ()
    | expectation :: _, [] -> Error (Missing_generic_attachment expectation.id)
    | [], attachment :: _ -> Error (Unexpected_generic_attachment attachment.id)
    | expectation :: expected_rest, attachment :: actual_rest ->
        let order = String.compare expectation.id attachment.id in
        if order < 0 then Error (Missing_generic_attachment expectation.id)
        else if order > 0 then
          Error (Unexpected_generic_attachment attachment.id)
        else if expectation.kind <> attachment.kind then
          Error
            (Generic_attachment_kind_mismatch
               {
                 id = expectation.id;
                 expected = expectation.kind;
                 actual = attachment.kind;
               })
        else loop expected_rest actual_rest
  in
  loop expected actual

let validate_response ~(request : request) ~(response : response) =
  if request.request_id <> response.request_id then
    Error
      (Request_id_mismatch
         { expected = request.request_id; actual = response.request_id })
  else if request.context_fingerprint <> response.context_fingerprint then
    Error
      (Context_fingerprint_mismatch
         {
           expected = request.context_fingerprint;
           actual = response.context_fingerprint;
         })
  else if request.probe_ast.digest <> response.ast_digest then
    Error
      (Ast_digest_mismatch
         { expected = request.probe_ast.digest; actual = response.ast_digest })
  else
    let expected = request.expected_markers in
    let actual = List.map (fun result -> result.marker) response.results in
    match
      List.find_opt
        (fun marker ->
          not
            (List.exists
               (fun actual ->
                 Marker.compare_id (Marker.id marker) (Marker.id actual) = 0)
               actual))
        expected
    with
    | Some marker -> Error (Missing_marker_result (Marker.id marker))
    | None -> (
        match
          List.find_opt
            (fun marker ->
              not
                (List.exists
                   (fun expected ->
                     Marker.compare_id (Marker.id marker) (Marker.id expected)
                     = 0)
                   expected))
            actual
        with
        | Some marker -> Error (Unexpected_marker_result (Marker.id marker))
        | None -> (
            match
              List.find_map
                (fun expected ->
                  match
                    List.find_opt
                      (fun actual ->
                        Marker.compare_id (Marker.id expected)
                          (Marker.id actual)
                        = 0)
                      actual
                  with
                  | None -> None
                  | Some actual ->
                      if Marker.equal expected actual then None
                      else Some (expected, actual))
                expected
            with
            | Some (expected, actual) ->
                Error (Marker_mismatch { expected; actual })
            | None ->
                validate_generic_attachments request.generic_expectations
                  response.generic_attachments))

let compare = Stdlib.compare
let equal first second = compare first second = 0

let kind_to_json kind = `String (Kind.to_string kind)

let kind_of_json path = function
  | `String "error" -> Ok Kind.Error
  | `String "requirement" -> Ok Kind.Requirement
  | `String value ->
      Error
        (Malformed
           {
             path;
             message = Printf.sprintf "unknown propagation kind %S" value;
           })
  | _ -> Error (Malformed { path; message = "expected a propagation kind" })

let malformed path message = Error (Malformed { path; message })

let as_object path = function
  | `Assoc fields -> Ok fields
  | _ -> malformed path "expected an object"

let field path name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> malformed (path @ [ name ]) "missing required field"

let optional_field name ~default fields =
  match List.assoc_opt name fields with Some value -> value | None -> default

let as_string path = function
  | `String value -> Ok value
  | _ -> malformed path "expected a string"

let as_int path = function
  | `Int value -> Ok value
  | _ -> malformed path "expected an integer"

let as_bool path = function
  | `Bool value -> Ok value
  | _ -> malformed path "expected a boolean"

let as_list path = function
  | `List values -> Ok values
  | _ -> malformed path "expected an array"

let ( let* ) value f =
  match value with Ok value -> f value | Error _ as error -> error

let decode_list decode path json =
  let* values = as_list path json in
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* value = decode (path @ [ string_of_int index ]) value in
        loop (index + 1) (value :: acc) rest
  in
  loop 0 [] values

let strings_to_json values =
  `List (List.map (fun value -> `String value) values)

let strings_of_json path json = decode_list as_string path json

let identity_to_json identity =
  `Assoc
    [
      ("module_path", strings_to_json (Identity.module_path identity));
      ("declaration", `String (Identity.declaration_name identity));
      ("interface_digest", `String (Identity.interface_digest identity));
    ]

let identity_of_json path json =
  let* fields = as_object path json in
  let* module_path_json = field path "module_path" fields in
  let* module_path =
    strings_of_json (path @ [ "module_path" ]) module_path_json
  in
  let* declaration_json = field path "declaration" fields in
  let* declaration = as_string (path @ [ "declaration" ]) declaration_json in
  let* digest_json = field path "interface_digest" fields in
  let* interface_digest =
    as_string (path @ [ "interface_digest" ]) digest_json
  in
  match
    Identity.make ~module_path ~declaration_name:declaration ~interface_digest
  with
  | Ok identity -> Ok identity
  | Error _ -> malformed path "invalid nominal declaration identity"

let primitive_to_string (primitive : Type_identity.primitive) =
  match primitive with
  | Type_identity.Unit -> "unit"
  | Type_identity.Bool -> "bool"
  | Type_identity.Char -> "char"
  | Type_identity.Int -> "int"
  | Type_identity.Int32 -> "int32"
  | Type_identity.Int64 -> "int64"
  | Type_identity.Nativeint -> "nativeint"
  | Type_identity.Float -> "float"
  | Type_identity.String -> "string"
  | Type_identity.Bytes -> "bytes"

let primitive_of_string path = function
  | "unit" -> Ok Type_identity.Unit
  | "bool" -> Ok Type_identity.Bool
  | "char" -> Ok Type_identity.Char
  | "int" -> Ok Type_identity.Int
  | "int32" -> Ok Type_identity.Int32
  | "int64" -> Ok Type_identity.Int64
  | "nativeint" -> Ok Type_identity.Nativeint
  | "float" -> Ok Type_identity.Float
  | "string" -> Ok Type_identity.String
  | "bytes" -> Ok Type_identity.Bytes
  | value -> malformed path (Printf.sprintf "unknown primitive type %S" value)

let rec type_identity_to_json identity =
  match Type_identity.view identity with
  | Primitive primitive ->
      `Assoc
        [
          ("kind", `String "primitive");
          ("name", `String (primitive_to_string primitive));
        ]
  | Tuple elements ->
      `Assoc
        [
          ("kind", `String "tuple");
          ("elements", `List (List.map type_identity_to_json elements));
        ]
  | Nominal { declaration; arguments } ->
      `Assoc
        [
          ("kind", `String "nominal");
          ("declaration", identity_to_json declaration);
          ("arguments", `List (List.map type_identity_to_json arguments));
        ]

let rec type_identity_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "primitive" ->
      let* name_json = field path "name" fields in
      let* name = as_string (path @ [ "name" ]) name_json in
      let* primitive = primitive_of_string (path @ [ "name" ]) name in
      Ok (Type_identity.primitive primitive)
  | "tuple" ->
      let* elements_json = field path "elements" fields in
      let* elements =
        decode_list type_identity_of_json (path @ [ "elements" ]) elements_json
      in
      begin match Type_identity.tuple elements with
      | Ok tuple -> Ok tuple
      | Error _ -> malformed path "tuple type requires at least two elements"
      end
  | "nominal" ->
      let* declaration_json = field path "declaration" fields in
      let* declaration =
        identity_of_json (path @ [ "declaration" ]) declaration_json
      in
      let* arguments_json = field path "arguments" fields in
      let* arguments =
        decode_list type_identity_of_json (path @ [ "arguments" ])
          arguments_json
      in
      Ok (Type_identity.nominal ~declaration ~arguments)
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unsupported payload type constructor %S" value)

let payload_to_json = function
  | Atom.No_payload -> `Assoc [ ("arity", `Int 0) ]
  | Atom.Payload identity ->
      `Assoc [ ("arity", `Int 1); ("type", type_identity_to_json identity) ]

let payload_of_json path json =
  let* fields = as_object path json in
  let* arity_json = field path "arity" fields in
  let* arity = as_int (path @ [ "arity" ]) arity_json in
  match arity with
  | 0 -> Ok Atom.No_payload
  | 1 ->
      let* type_json = field path "type" fields in
      let* identity = type_identity_of_json (path @ [ "type" ]) type_json in
      Ok (Atom.Payload identity)
  | arity ->
      malformed (path @ [ "arity" ])
        (Printf.sprintf "unsupported variant payload arity %d" arity)

let atom_to_json atom =
  `Assoc
    [
      ("kind", kind_to_json (Atom.kind atom));
      ("declaration", identity_to_json (Atom.declaration atom));
      ("label", `String (Atom.label atom));
      ("payload", payload_to_json (Atom.payload atom));
    ]

let atom_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
  let* declaration_json = field path "declaration" fields in
  let* declaration =
    identity_of_json (path @ [ "declaration" ]) declaration_json
  in
  let* label_json = field path "label" fields in
  let* label = as_string (path @ [ "label" ]) label_json in
  let* payload_json = field path "payload" fields in
  let* payload = payload_of_json (path @ [ "payload" ]) payload_json in
  match Atom.make ~kind ~declaration ~label ~payload with
  | Ok atom -> Ok atom
  | Error _ -> malformed path "invalid variant atom"

let unavailable_reason_to_string = function
  | Leaf.Abstract_declaration -> "abstract_declaration"
  | Leaf.Hidden_alias -> "hidden_alias"
  | Leaf.Missing_cases_catalogue -> "missing_cases_catalogue"
  | Leaf.No_named_pattern -> "no_named_pattern"
  | Leaf.Grouped_requirement -> "grouped_requirement"

let unavailable_reason_of_string path = function
  | "abstract_declaration" -> Ok Leaf.Abstract_declaration
  | "hidden_alias" -> Ok Leaf.Hidden_alias
  | "missing_cases_catalogue" -> Ok Leaf.Missing_cases_catalogue
  | "no_named_pattern" -> Ok Leaf.No_named_pattern
  | "grouped_requirement" -> Ok Leaf.Grouped_requirement
  | value ->
      malformed path (Printf.sprintf "unknown materialization refusal %S" value)

let materialization_to_json = function
  | Leaf.Direct -> `Assoc [ ("kind", `String "direct") ]
  | Leaf.Structural_variant -> `Assoc [ ("kind", `String "structural_variant") ]
  | Leaf.Error_cases { catalogue; union; field } ->
      `Assoc
        [
          ("kind", `String "error_cases");
          ("catalogue", identity_to_json catalogue);
          ("union", identity_to_json union);
          ("field", `String field);
        ]
  | Leaf.Requirement_tag -> `Assoc [ ("kind", `String "requirement_tag") ]
  | Leaf.Unavailable reason ->
      `Assoc
        [
          ("kind", `String "unavailable");
          ("reason", `String (unavailable_reason_to_string reason));
        ]

let materialization_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "direct" -> Ok Leaf.Direct
  | "structural_variant" -> Ok Leaf.Structural_variant
  | "error_cases" ->
      let* catalogue_json = field path "catalogue" fields in
      let* catalogue =
        identity_of_json (path @ [ "catalogue" ]) catalogue_json
      in
      let* union_json = field path "union" fields in
      let* union = identity_of_json (path @ [ "union" ]) union_json in
      let* field_json = field path "field" fields in
      let* field = as_string (path @ [ "field" ]) field_json in
      Ok (Leaf.Error_cases { catalogue; union; field })
  | "requirement_tag" -> Ok Leaf.Requirement_tag
  | "unavailable" ->
      let* reason_json = field path "reason" fields in
      let* reason = as_string (path @ [ "reason" ]) reason_json in
      let* reason = unavailable_reason_of_string (path @ [ "reason" ]) reason in
      Ok (Leaf.Unavailable reason)
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown materialization kind %S" value)

let leaf_to_json leaf =
  `Assoc
    [
      ("identity", identity_to_json (Leaf.identity leaf));
      ("kind", kind_to_json (Leaf.kind leaf));
      ("members", `List (List.map atom_to_json (Leaf.members leaf)));
      ("materialization", materialization_to_json (Leaf.materialization leaf));
    ]

let leaf_of_json path json =
  let* fields = as_object path json in
  let* identity_json = field path "identity" fields in
  let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
  let* kind_json = field path "kind" fields in
  let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
  let* members_json = field path "members" fields in
  let* members = decode_list atom_of_json (path @ [ "members" ]) members_json in
  let* materialization_json = field path "materialization" fields in
  let* materialization =
    materialization_of_json (path @ [ "materialization" ]) materialization_json
  in
  match (kind, members) with
  | Kind.Error, _ -> (
      match Leaf.error ~identity ~members ~materialization with
      | Ok leaf -> Ok leaf
      | Error _ -> malformed path "invalid error leaf")
  | Kind.Requirement, [ member ] -> (
      match Leaf.requirement ~identity ~member ~materialization with
      | Ok leaf -> Ok leaf
      | Error _ -> malformed path "invalid requirement leaf")
  | Kind.Requirement, _ ->
      malformed (path @ [ "members" ])
        "an exact requirement leaf must contain exactly one member"

let composition_to_string = function
  | Proof.Return -> "return"
  | Proof.Fail -> "fail"
  | Proof.Summon -> "summon"
  | Proof.Chain -> "chain"
  | Proof.Map -> "map"
  | Proof.Catch -> "catch"
  | Proof.Provide -> "provide"

let composition_of_string path = function
  | "return" -> Ok Proof.Return
  | "fail" -> Ok Proof.Fail
  | "summon" -> Ok Proof.Summon
  | "chain" -> Ok Proof.Chain
  | "map" -> Ok Proof.Map
  | "catch" -> Ok Proof.Catch
  | "provide" -> Ok Proof.Provide
  | value ->
      malformed path (Printf.sprintf "unknown proof composition %S" value)

let origin_to_json = function
  | Proof.Closed_row -> `Assoc [ ("kind", `String "closed_row") ]
  | Proof.Generalized_value identity ->
      `Assoc
        [
          ("kind", `String "generalized_value");
          ("declaration", identity_to_json identity);
        ]
  | Proof.External_value identity ->
      `Assoc
        [
          ("kind", `String "external_value");
          ("declaration", identity_to_json identity);
        ]
  | Proof.Composition { operation; inputs } ->
      `Assoc
        [
          ("kind", `String "composition");
          ("operation", `String (composition_to_string operation));
          ("inputs", inputs |> List.map Marker.id_to_string |> strings_to_json);
        ]

let marker_ids_of_json path json =
  let* values = strings_of_json path json in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match Marker.id_of_string value with
        | Ok id -> loop (id :: acc) rest
        | Error _ -> malformed path "invalid marker identity")
  in
  loop [] values

let origin_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "closed_row" -> Ok Proof.Closed_row
  | "generalized_value" ->
      let* declaration_json = field path "declaration" fields in
      let* declaration =
        identity_of_json (path @ [ "declaration" ]) declaration_json
      in
      Ok (Proof.Generalized_value declaration)
  | "external_value" ->
      let* declaration_json = field path "declaration" fields in
      let* declaration =
        identity_of_json (path @ [ "declaration" ]) declaration_json
      in
      Ok (Proof.External_value declaration)
  | "composition" ->
      let* operation_json = field path "operation" fields in
      let* operation_name = as_string (path @ [ "operation" ]) operation_json in
      let* operation =
        composition_of_string (path @ [ "operation" ]) operation_name
      in
      let* inputs_json = field path "inputs" fields in
      let* inputs = marker_ids_of_json (path @ [ "inputs" ]) inputs_json in
      Ok (Proof.Composition { operation; inputs })
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown proof origin %S" value)

let proof_to_json proof =
  `Assoc
    [
      ("kind", kind_to_json (Proof.kind proof));
      ("origin", origin_to_json (Proof.origin proof));
      ("leaves", `List (List.map leaf_to_json (Proof.leaves proof)));
    ]

let proof_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
  let* origin_json = field path "origin" fields in
  let* origin = origin_of_json (path @ [ "origin" ]) origin_json in
  let* leaves_json = field path "leaves" fields in
  let* leaves = decode_list leaf_of_json (path @ [ "leaves" ]) leaves_json in
  match Proof.create ~kind ~origin ~leaves with
  | Ok proof -> Ok proof
  | Error _ ->
      malformed path
        "invalid exact proof partition or channel; tag-only observations are \
         not exact proofs"

let span_to_json span =
  `Assoc
    [
      ("file", `String (Source_span.file span));
      ("start_offset", `Int (Source_span.start_offset span));
      ("end_offset", `Int (Source_span.end_offset span));
      ("start_line", `Int (Source_span.start_line span));
      ("start_column", `Int (Source_span.start_column span));
      ("end_line", `Int (Source_span.end_line span));
      ("end_column", `Int (Source_span.end_column span));
    ]

let span_of_json path json =
  let* fields = as_object path json in
  let get_string name =
    let* json = field path name fields in
    as_string (path @ [ name ]) json
  in
  let get_int name =
    let* json = field path name fields in
    as_int (path @ [ name ]) json
  in
  let* file = get_string "file" in
  let* start_offset = get_int "start_offset" in
  let* end_offset = get_int "end_offset" in
  let* start_line = get_int "start_line" in
  let* start_column = get_int "start_column" in
  let* end_line = get_int "end_line" in
  let* end_column = get_int "end_column" in
  match
    Source_span.make ~file ~start_offset ~end_offset ~start_line ~start_column
      ~end_line ~end_column
  with
  | Ok span -> Ok span
  | Error _ -> malformed path "invalid source span"

let marker_to_json marker =
  `Assoc
    [
      ("id", `String (marker |> Marker.id |> Marker.id_to_string));
      ("kind", kind_to_json (Marker.kind marker));
      ("span", span_to_json (Marker.span marker));
    ]

let marker_of_json path json =
  let* fields = as_object path json in
  let* id_json = field path "id" fields in
  let* id_value = as_string (path @ [ "id" ]) id_json in
  let* id =
    match Marker.id_of_string id_value with
    | Ok id -> Ok id
    | Error _ -> malformed (path @ [ "id" ]) "invalid marker identity"
  in
  let* kind_json = field path "kind" fields in
  let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
  let* span_json = field path "span" fields in
  let* span = span_of_json (path @ [ "span" ]) span_json in
  Ok (Marker.make ~id ~kind ~span)

let tool_context_to_json context =
  `Assoc
    [
      ("ocaml_version", `String context.ocaml_version);
      ("hamlet_subtractor_version", `String context.hamlet_subtractor_version);
      ("resolver_version", `String context.resolver_version);
      ("catalogue_schema_version", `Int context.catalogue_schema_version);
    ]

let tool_context_of_json path json =
  let* fields = as_object path json in
  let get_string name =
    let* json = field path name fields in
    as_string (path @ [ name ]) json
  in
  let* ocaml_version = get_string "ocaml_version" in
  let* hamlet_subtractor_version = get_string "hamlet_subtractor_version" in
  let* resolver_version = get_string "resolver_version" in
  let* catalogue_json = field path "catalogue_schema_version" fields in
  let* catalogue_schema_version =
    as_int (path @ [ "catalogue_schema_version" ]) catalogue_json
  in
  let context =
    {
      ocaml_version;
      hamlet_subtractor_version;
      resolver_version;
      catalogue_schema_version;
    }
  in
  match validate_tool_context context with
  | Ok () -> Ok context
  | Error _ -> malformed path "invalid tool context"

let package_mode_to_json = function
  | Standalone -> `Assoc [ ("kind", `String "standalone") ]
  | For_pack pack ->
      `Assoc [ ("kind", `String "for_pack"); ("pack", `String pack) ]

let package_mode_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "standalone" -> Ok Standalone
  | "for_pack" ->
      let* pack_json = field path "pack" fields in
      let* pack = as_string (path @ [ "pack" ]) pack_json in
      if String.trim pack = "" then
        malformed (path @ [ "pack" ]) "pack name is empty"
      else Ok (For_pack pack)
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown package mode %S" value)

let compiler_flags_to_json flags =
  `Assoc
    [
      ("debug", `Bool flags.debug);
      ("principal", `Bool flags.principal);
      ("recursive_types", `Bool flags.recursive_types);
      ("alias_dependencies", `Bool flags.alias_dependencies);
      ("use_threads", `Bool flags.use_threads);
      ("unboxed_types", `Bool flags.unboxed_types);
    ]

let compiler_flags_of_json path json =
  let* fields = as_object path json in
  let get_bool name =
    let* json = field path name fields in
    as_bool (path @ [ name ]) json
  in
  let* debug = get_bool "debug" in
  let* principal = get_bool "principal" in
  let* recursive_types = get_bool "recursive_types" in
  let* alias_dependencies = get_bool "alias_dependencies" in
  let* use_threads = get_bool "use_threads" in
  let* unboxed_types = get_bool "unboxed_types" in
  Ok
    {
      debug;
      principal;
      recursive_types;
      alias_dependencies;
      use_threads;
      unboxed_types;
    }

let ast_descriptor_to_json descriptor =
  `Assoc
    [
      ("path", `String descriptor.path);
      ("input_name", `String descriptor.input_name);
      ("magic", `String descriptor.magic);
      ("digest", `String descriptor.digest);
      ("byte_length", `Int descriptor.byte_length);
    ]

let ast_descriptor_of_json path json =
  let* fields = as_object path json in
  let get_string name =
    let* json = field path name fields in
    as_string (path @ [ name ]) json
  in
  let* descriptor_path = get_string "path" in
  let* input_name = get_string "input_name" in
  let* magic = get_string "magic" in
  let* digest = get_string "digest" in
  let* byte_length_json = field path "byte_length" fields in
  let* byte_length = as_int (path @ [ "byte_length" ]) byte_length_json in
  Ok { path = descriptor_path; input_name; magic; digest; byte_length }

let probe_unit_to_json = function
  | Synthetic_unit name ->
      `Assoc [ ("kind", `String "synthetic"); ("name", `String name) ]

let probe_unit_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "synthetic" ->
      let* name_json = field path "name" fields in
      let* name = as_string (path @ [ "name" ]) name_json in
      Ok (Synthetic_unit name)
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown probe unit kind %S" value)

let generic_attachment_kind_to_json = function
  | Definition -> `String "definition"
  | Call -> `String "call"

let generic_attachment_kind_of_json path = function
  | `String "definition" -> Ok Definition
  | `String "call" -> Ok Call
  | `String value ->
      malformed path (Printf.sprintf "unknown generic attachment kind %S" value)
  | _ -> malformed path "expected a generic attachment kind"

let generic_expectation_to_json (expectation : generic_expectation) =
  `Assoc
    [
      ("id", `String expectation.id);
      ("kind", generic_attachment_kind_to_json expectation.kind);
    ]

let generic_expectation_of_json path json =
  let* fields = as_object path json in
  let* id_json = field path "id" fields in
  let* id = as_string (path @ [ "id" ]) id_json in
  let* kind_json = field path "kind" fields in
  let* kind = generic_attachment_kind_of_json (path @ [ "kind" ]) kind_json in
  match generic_expectation ~id ~kind with
  | Ok expectation -> Ok expectation
  | Error Empty_generic_attachment_id ->
      malformed (path @ [ "id" ]) "generic attachment identity is empty"
  | Error _ -> malformed path "invalid generic attachment expectation"

let generic_attachment_to_json (attachment : generic_attachment) =
  `Assoc
    [
      ("id", `String attachment.id);
      ("kind", generic_attachment_kind_to_json attachment.kind);
      ("payload", `String attachment.payload);
    ]

let generic_attachment_of_json path json =
  let* fields = as_object path json in
  let* id_json = field path "id" fields in
  let* id = as_string (path @ [ "id" ]) id_json in
  let* kind_json = field path "kind" fields in
  let* kind = generic_attachment_kind_of_json (path @ [ "kind" ]) kind_json in
  let* payload_json = field path "payload" fields in
  let* payload = as_string (path @ [ "payload" ]) payload_json in
  match generic_attachment ~id ~kind ~payload with
  | Ok attachment -> Ok attachment
  | Error Empty_generic_attachment_id ->
      malformed (path @ [ "id" ]) "generic attachment identity is empty"
  | Error (Empty_generic_attachment_payload _) ->
      malformed (path @ [ "payload" ]) "generic attachment payload is empty"
  | Error (Generic_attachment_payload_too_large { limit; actual; _ }) ->
      malformed (path @ [ "payload" ])
        (Printf.sprintf
           "generic attachment payload is too large: %d bytes exceeds %d" actual
           limit)
  | Error _ -> malformed path "invalid generic attachment"

let request_to_json (request : request) =
  `Assoc
    [
      ("protocol", `String "hamlet-subtractor-request");
      ("version", `Int version);
      ("request_id", `String request.request_id);
      ("source_file", `String request.source_file);
      ("tool_name", `String request.tool_name);
      ("probe_ast", ast_descriptor_to_json request.probe_ast);
      ("probe_unit", probe_unit_to_json request.probe_unit);
      ("tool_context", tool_context_to_json request.tool_context);
      ("context_fingerprint", `String request.context_fingerprint);
      ("include_dirs", strings_to_json request.include_dirs);
      ("hidden_include_dirs", strings_to_json request.hidden_include_dirs);
      ("visible_paths", strings_to_json request.visible_paths);
      ("hidden_paths", strings_to_json request.hidden_paths);
      ("opens", strings_to_json request.opens);
      ("package_mode", package_mode_to_json request.package_mode);
      ("compiler_flags", compiler_flags_to_json request.compiler_flags);
      ( "expected_markers",
        `List (List.map marker_to_json request.expected_markers) );
      ( "generic_expectations",
        `List
          (List.map generic_expectation_to_json request.generic_expectations) );
    ]

let encode_request request = Yojson.Basic.to_string (request_to_json request)

let request_of_json json =
  let path = [] in
  let* fields = as_object path json in
  let* protocol_json = field path "protocol" fields in
  let* protocol = as_string [ "protocol" ] protocol_json in
  let* () =
    if protocol = "hamlet-subtractor-request" then Ok ()
    else malformed [ "protocol" ] "unexpected protocol name"
  in
  let* version_json = field path "version" fields in
  let* actual = as_int [ "version" ] version_json in
  let* () =
    if actual = version then Ok ()
    else Error (Version_mismatch { expected = version; actual })
  in
  let get_string name =
    let* json = field path name fields in
    as_string [ name ] json
  in
  let get_strings name =
    let* json = field path name fields in
    strings_of_json [ name ] json
  in
  let* request_id = get_string "request_id" in
  let* source_file = get_string "source_file" in
  let* tool_name = get_string "tool_name" in
  let* probe_ast_json = field path "probe_ast" fields in
  let* probe_ast = ast_descriptor_of_json [ "probe_ast" ] probe_ast_json in
  let* probe_unit_json = field path "probe_unit" fields in
  let* probe_unit = probe_unit_of_json [ "probe_unit" ] probe_unit_json in
  let* tool_json = field path "tool_context" fields in
  let* tool_context = tool_context_of_json [ "tool_context" ] tool_json in
  let* context_fingerprint = get_string "context_fingerprint" in
  let* include_dirs = get_strings "include_dirs" in
  let* hidden_include_dirs = get_strings "hidden_include_dirs" in
  let* visible_paths = get_strings "visible_paths" in
  let* hidden_paths = get_strings "hidden_paths" in
  let* opens = get_strings "opens" in
  let* package_json = field path "package_mode" fields in
  let* package_mode = package_mode_of_json [ "package_mode" ] package_json in
  let* compiler_json = field path "compiler_flags" fields in
  let* compiler_flags =
    compiler_flags_of_json [ "compiler_flags" ] compiler_json
  in
  let* markers_json = field path "expected_markers" fields in
  let* expected_markers =
    decode_list marker_of_json [ "expected_markers" ] markers_json
  in
  let generic_expectations_json =
    optional_field "generic_expectations" ~default:(`List []) fields
  in
  let* generic_expectations =
    decode_list generic_expectation_of_json [ "generic_expectations" ]
      generic_expectations_json
  in
  match
    request_with_generic_expectations ~generic_expectations ~request_id
      ~source_file ~tool_name ~probe_ast ~probe_unit ~tool_context
      ~context_fingerprint ~include_dirs ~hidden_include_dirs ~visible_paths
      ~hidden_paths ~opens ~package_mode ~compiler_flags ~expected_markers
  with
  | Ok request -> Ok request
  | Error Empty_request_id ->
      malformed [ "request_id" ] "request identity must not be empty"
  | Error Empty_context_fingerprint ->
      malformed [ "context_fingerprint" ]
        "context fingerprint must not be empty"
  | Error Empty_source_file ->
      malformed [ "source_file" ] "source file must not be empty"
  | Error Empty_tool_name ->
      malformed [ "tool_name" ] "tool name must not be empty"
  | Error Empty_ast_path -> malformed [ "probe_ast"; "path" ] "path is empty"
  | Error Relative_ast_path ->
      malformed [ "probe_ast"; "path" ] "path must be absolute"
  | Error Empty_ast_input_name ->
      malformed [ "probe_ast"; "input_name" ] "input name is empty"
  | Error Empty_ast_magic ->
      malformed [ "probe_ast"; "magic" ] "AST magic is empty"
  | Error Empty_ast_digest ->
      malformed [ "probe_ast"; "digest" ] "AST digest is empty"
  | Error (Invalid_ast_byte_length _) ->
      malformed [ "probe_ast"; "byte_length" ] "AST length must be positive"
  | Error Empty_synthetic_unit ->
      malformed [ "probe_unit"; "name" ] "synthetic unit name is empty"
  | Error (Duplicate_marker marker) ->
      malformed [ "expected_markers" ]
        (Printf.sprintf "duplicate marker %S" (Marker.id_to_string marker))
  | Error (Duplicate_generic_expectation id) ->
      malformed [ "generic_expectations" ]
        (Printf.sprintf "duplicate generic attachment expectation %S" id)
  | Error Empty_for_pack ->
      malformed [ "package_mode" ] "pack name must not be empty"
  | Error (Empty_tool_version field) ->
      malformed [ "tool_context"; field ] "tool version must not be empty"
  | Error (Invalid_catalogue_schema_version _) ->
      malformed
        [ "tool_context"; "catalogue_schema_version" ]
        "catalogue schema version must be positive"
  | Error _ -> malformed [] "invalid resolver request"

let decode_request input =
  try request_of_json (Yojson.Basic.from_string input)
  with Yojson.Json_error message -> malformed [] message

let guard_to_string = function
  | Residual.Unguarded -> "unguarded"
  | Residual.Guarded -> "guarded"
let action_to_string = function
  | Residual.Handle -> "handle"
  | Residual.Forward -> "forward"

let guard_of_string path = function
  | "unguarded" -> Ok Residual.Unguarded
  | "guarded" -> Ok Residual.Guarded
  | value -> malformed path (Printf.sprintf "unknown arm guard %S" value)

let action_of_string path = function
  | "handle" -> Ok Residual.Handle
  | "forward" -> Ok Residual.Forward
  | value -> malformed path (Printf.sprintf "unknown arm action %S" value)

let target_to_json = function
  | Residual.Complete_leaf identity ->
      `Assoc
        [
          ("kind", `String "complete_leaf");
          ("identity", identity_to_json identity);
        ]
  | Residual.Structural_member atom ->
      `Assoc
        [ ("kind", `String "structural_member"); ("atom", atom_to_json atom) ]

let target_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "complete_leaf" ->
      let* identity_json = field path "identity" fields in
      let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
      Ok (Residual.Complete_leaf identity)
  | "structural_member" ->
      let* atom_json = field path "atom" fields in
      let* atom = atom_of_json (path @ [ "atom" ]) atom_json in
      Ok (Residual.Structural_member atom)
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown arm target %S" value)

let arm_to_json arm =
  `Assoc
    [
      ("target", target_to_json (Residual.target arm));
      ("guard", `String (guard_to_string (Residual.guard arm)));
      ("action", `String (action_to_string (Residual.action arm)));
    ]

let arm_of_json path json =
  let* fields = as_object path json in
  let* target_json = field path "target" fields in
  let* target = target_of_json (path @ [ "target" ]) target_json in
  let* guard_json = field path "guard" fields in
  let* guard_name = as_string (path @ [ "guard" ]) guard_json in
  let* guard = guard_of_string (path @ [ "guard" ]) guard_name in
  let* action_json = field path "action" fields in
  let* action_name = as_string (path @ [ "action" ]) action_json in
  let* action = action_of_string (path @ [ "action" ]) action_name in
  Ok (Residual.arm ~target ~guard ~action)

let residual_to_json calculation =
  `Assoc
    [
      ("input", proof_to_json (Residual.input calculation));
      ("arms", `List (List.map arm_to_json (Residual.arms calculation)));
      ("recovery", `List (List.map leaf_to_json (Residual.recovery calculation)));
    ]

let residual_of_json path json =
  let* fields = as_object path json in
  let* input_json = field path "input" fields in
  let* input = proof_of_json (path @ [ "input" ]) input_json in
  let* arms_json = field path "arms" fields in
  let* arms = decode_list arm_of_json (path @ [ "arms" ]) arms_json in
  let* recovery_json = field path "recovery" fields in
  let* recovery =
    decode_list leaf_of_json (path @ [ "recovery" ]) recovery_json
  in
  match Residual.calculate ~input ~arms ~recovery with
  | Ok calculation -> Ok calculation
  | Error _ -> malformed path "invalid or refusing residual calculation"

let payload_shape_to_string = function
  | Diagnostic.Function -> "function"
  | Diagnostic.Object -> "object"
  | Diagnostic.Unresolved_variable -> "unresolved_variable"
  | Diagnostic.Open_variant -> "open_variant"
  | Diagnostic.Package -> "package"
  | Diagnostic.Unsupported_structural_type -> "unsupported_structural_type"

let payload_shape_of_string path = function
  | "function" -> Ok Diagnostic.Function
  | "object" -> Ok Diagnostic.Object
  | "unresolved_variable" -> Ok Diagnostic.Unresolved_variable
  | "open_variant" -> Ok Diagnostic.Open_variant
  | "package" -> Ok Diagnostic.Package
  | "unsupported_structural_type" -> Ok Diagnostic.Unsupported_structural_type
  | value ->
      malformed path (Printf.sprintf "unknown payload refusal shape %S" value)

let optional_identity_to_json = function
  | None -> `Null
  | Some identity -> identity_to_json identity

let optional_identity_of_json path = function
  | `Null -> Ok None
  | json ->
      let* identity = identity_of_json path json in
      Ok (Some identity)

let code_to_json = function
  | Diagnostic.Open_row -> `Assoc [ ("code", `String "open_row") ]
  | Diagnostic.Abstract_alias identity ->
      `Assoc
        [
          ("code", `String "abstract_alias");
          ("declaration", optional_identity_to_json identity);
        ]
  | Diagnostic.Unresolved_row -> `Assoc [ ("code", `String "unresolved_row") ]
  | Diagnostic.Polymorphic_parameter ->
      `Assoc [ ("code", `String "polymorphic_parameter") ]
  | Diagnostic.Opaque_origin -> `Assoc [ ("code", `String "opaque_origin") ]
  | Diagnostic.Higher_order_flow ->
      `Assoc [ ("code", `String "higher_order_flow") ]
  | Diagnostic.Invalid_owner -> `Assoc [ ("code", `String "invalid_owner") ]
  | Diagnostic.Invalid_error_catalogue reason ->
      `Assoc
        [
          ("code", `String "invalid_error_catalogue"); ("reason", `String reason);
        ]
  | Diagnostic.Unsupported_pattern ->
      `Assoc [ ("code", `String "unsupported_pattern") ]
  | Diagnostic.Unsupported_handler_rhs ->
      `Assoc [ ("code", `String "unsupported_handler_rhs") ]
  | Diagnostic.Ambiguous_handler ->
      `Assoc [ ("code", `String "ambiguous_handler") ]
  | Diagnostic.Recursive_dependency markers ->
      `Assoc
        [
          ("code", `String "recursive_dependency");
          ("markers", markers |> List.map Marker.id_to_string |> strings_to_json);
        ]
  | Diagnostic.Unsupported_payload { declaration; shape } ->
      `Assoc
        [
          ("code", `String "unsupported_payload");
          ("declaration", optional_identity_to_json declaration);
          ("shape", `String (payload_shape_to_string shape));
        ]
  | Diagnostic.Leaf_outside_universe identity ->
      `Assoc
        [
          ("code", `String "leaf_outside_universe");
          ("identity", identity_to_json identity);
        ]
  | Diagnostic.Atoms_outside_universe atoms ->
      `Assoc
        [
          ("code", `String "atoms_outside_universe");
          ("atoms", `List (List.map atom_to_json atoms));
        ]
  | Diagnostic.Partially_handled_group { leaf; matched } ->
      `Assoc
        [
          ("code", `String "partially_handled_group");
          ("leaf", leaf_to_json leaf);
          ("matched", `List (List.map atom_to_json matched));
        ]
  | Diagnostic.Unmaterializable_leaf leaf ->
      `Assoc
        [
          ("code", `String "unmaterializable_leaf"); ("leaf", leaf_to_json leaf);
        ]
  | Diagnostic.Grouped_requirement identity ->
      `Assoc
        [
          ("code", `String "grouped_requirement");
          ("identity", identity_to_json identity);
        ]
  | Diagnostic.Duplicate_unguarded_arm identity ->
      `Assoc
        [
          ("code", `String "duplicate_unguarded_arm");
          ("identity", identity_to_json identity);
        ]
  | Diagnostic.Conflicting_recovery_leaf identity ->
      `Assoc
        [
          ("code", `String "conflicting_recovery_leaf");
          ("identity", identity_to_json identity);
        ]
  | Diagnostic.Wrong_channel { expected; actual } ->
      `Assoc
        [
          ("code", `String "wrong_channel");
          ("expected", kind_to_json expected);
          ("actual", kind_to_json actual);
        ]

let code_of_json path json =
  let* fields = as_object path json in
  let* code_json = field path "code" fields in
  let* code = as_string (path @ [ "code" ]) code_json in
  match code with
  | "open_row" -> Ok Diagnostic.Open_row
  | "abstract_alias" ->
      let* declaration_json = field path "declaration" fields in
      let* declaration =
        optional_identity_of_json (path @ [ "declaration" ]) declaration_json
      in
      Ok (Diagnostic.Abstract_alias declaration)
  | "unresolved_row" -> Ok Diagnostic.Unresolved_row
  | "polymorphic_parameter" -> Ok Diagnostic.Polymorphic_parameter
  | "opaque_origin" -> Ok Diagnostic.Opaque_origin
  | "higher_order_flow" -> Ok Diagnostic.Higher_order_flow
  | "invalid_owner" -> Ok Diagnostic.Invalid_owner
  | "invalid_error_catalogue" ->
      let* reason_json = field path "reason" fields in
      let* reason = as_string (path @ [ "reason" ]) reason_json in
      Ok (Diagnostic.Invalid_error_catalogue reason)
  | "unsupported_pattern" -> Ok Diagnostic.Unsupported_pattern
  | "unsupported_handler_rhs" -> Ok Diagnostic.Unsupported_handler_rhs
  | "ambiguous_handler" -> Ok Diagnostic.Ambiguous_handler
  | "recursive_dependency" ->
      let* markers_json = field path "markers" fields in
      let* markers = marker_ids_of_json (path @ [ "markers" ]) markers_json in
      Ok (Diagnostic.Recursive_dependency markers)
  | "unsupported_payload" ->
      let* declaration_json = field path "declaration" fields in
      let* declaration =
        optional_identity_of_json (path @ [ "declaration" ]) declaration_json
      in
      let* shape_json = field path "shape" fields in
      let* shape_name = as_string (path @ [ "shape" ]) shape_json in
      let* shape = payload_shape_of_string (path @ [ "shape" ]) shape_name in
      Ok (Diagnostic.Unsupported_payload { declaration; shape })
  | "leaf_outside_universe" ->
      let* identity_json = field path "identity" fields in
      let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
      Ok (Diagnostic.Leaf_outside_universe identity)
  | "atoms_outside_universe" ->
      let* atoms_json = field path "atoms" fields in
      let* atoms = decode_list atom_of_json (path @ [ "atoms" ]) atoms_json in
      Ok (Diagnostic.Atoms_outside_universe atoms)
  | "partially_handled_group" ->
      let* leaf_json = field path "leaf" fields in
      let* leaf = leaf_of_json (path @ [ "leaf" ]) leaf_json in
      let* matched_json = field path "matched" fields in
      let* matched =
        decode_list atom_of_json (path @ [ "matched" ]) matched_json
      in
      Ok (Diagnostic.Partially_handled_group { leaf; matched })
  | "unmaterializable_leaf" ->
      let* leaf_json = field path "leaf" fields in
      let* leaf = leaf_of_json (path @ [ "leaf" ]) leaf_json in
      Ok (Diagnostic.Unmaterializable_leaf leaf)
  | "grouped_requirement" ->
      let* identity_json = field path "identity" fields in
      let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
      Ok (Diagnostic.Grouped_requirement identity)
  | "duplicate_unguarded_arm" ->
      let* identity_json = field path "identity" fields in
      let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
      Ok (Diagnostic.Duplicate_unguarded_arm identity)
  | "conflicting_recovery_leaf" ->
      let* identity_json = field path "identity" fields in
      let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
      Ok (Diagnostic.Conflicting_recovery_leaf identity)
  | "wrong_channel" ->
      let* expected_json = field path "expected" fields in
      let* expected = kind_of_json (path @ [ "expected" ]) expected_json in
      let* actual_json = field path "actual" fields in
      let* actual = kind_of_json (path @ [ "actual" ]) actual_json in
      Ok (Diagnostic.Wrong_channel { expected; actual })
  | value ->
      malformed (path @ [ "code" ])
        (Printf.sprintf "unknown refusal code %S" value)

let outcome_to_json = function
  | Resolved calculation ->
      `Assoc
        [
          ("kind", `String "resolved");
          ("calculation", residual_to_json calculation);
        ]
  | Refused diagnostic ->
      `Assoc
        [
          ("kind", `String "refused");
          ("diagnostic", code_to_json (Diagnostic.code diagnostic));
        ]

let outcome_of_json marker path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "resolved" ->
      let* calculation_json = field path "calculation" fields in
      let* calculation =
        residual_of_json (path @ [ "calculation" ]) calculation_json
      in
      Ok (Resolved calculation)
  | "refused" ->
      let* diagnostic_json = field path "diagnostic" fields in
      let* code = code_of_json (path @ [ "diagnostic" ]) diagnostic_json in
      Ok (Refused (Diagnostic.make ~marker ~code))
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown marker outcome %S" value)

let opacity_to_string = function
  | Effect_certificate.Unproven_origin -> "unproven_origin"
  | Effect_certificate.Opaque_recovery -> "opaque_recovery"
  | Effect_certificate.Opaque_handler -> "opaque_handler"

let opacity_of_string path = function
  | "unproven_origin" -> Ok Effect_certificate.Unproven_origin
  | "opaque_recovery" -> Ok Effect_certificate.Opaque_recovery
  | "opaque_handler" -> Ok Effect_certificate.Opaque_handler
  | value ->
      malformed path (Printf.sprintf "unknown certificate opacity %S" value)

let evidence_to_json evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Exact_proof proof ->
      `Assoc [ ("kind", `String "exact"); ("proof", proof_to_json proof) ]
  | Effect_certificate.Opaque_reasons reasons ->
      `Assoc
        [
          ("kind", `String "opaque");
          ( "reasons",
            `List
              (List.map
                 (fun reason -> `String (opacity_to_string reason))
                 reasons) );
        ]

let evidence_of_json path json =
  let* fields = as_object path json in
  let* kind_json = field path "kind" fields in
  let* kind = as_string (path @ [ "kind" ]) kind_json in
  match kind with
  | "exact" ->
      let* proof_json = field path "proof" fields in
      let* proof = proof_of_json (path @ [ "proof" ]) proof_json in
      Ok (Effect_certificate.exact proof)
  | "opaque" ->
      let* reasons_json = field path "reasons" fields in
      let* reasons =
        decode_list
          (fun reason_path json ->
            let* value = as_string reason_path json in
            opacity_of_string reason_path value)
          (path @ [ "reasons" ]) reasons_json
      in
      begin match Effect_certificate.opaque_many reasons with
      | Some evidence -> Ok evidence
      | None -> malformed (path @ [ "reasons" ]) "opacity list is empty"
      end
  | value ->
      malformed (path @ [ "kind" ])
        (Printf.sprintf "unknown certificate evidence %S" value)

let certificate_to_json certificate =
  `Assoc
    [
      ("errors", evidence_to_json (Effect_certificate.errors certificate));
      ( "requirements",
        evidence_to_json (Effect_certificate.requirements certificate) );
    ]

let certificate_of_json path json =
  let* fields = as_object path json in
  let* errors_json = field path "errors" fields in
  let* errors = evidence_of_json (path @ [ "errors" ]) errors_json in
  let* requirements_json = field path "requirements" fields in
  let* requirements =
    evidence_of_json (path @ [ "requirements" ]) requirements_json
  in
  match Effect_certificate.create ~errors ~requirements with
  | Ok certificate -> Ok certificate
  | Error _ -> malformed path "certificate channel evidence is invalid"

let certificate_option_to_json = function
  | None -> `Null
  | Some certificate -> certificate_to_json certificate

let certificate_option_of_json path = function
  | `Null -> Ok None
  | json ->
      let* certificate = certificate_of_json path json in
      Ok (Some certificate)

let marker_result_to_json result =
  `Assoc
    [
      ("marker", marker_to_json result.marker);
      ("outcome", outcome_to_json result.outcome);
      ("certificate", certificate_option_to_json result.certificate);
    ]

let marker_result_of_json path json =
  let* fields = as_object path json in
  let* marker_json = field path "marker" fields in
  let* marker = marker_of_json (path @ [ "marker" ]) marker_json in
  let* outcome_json = field path "outcome" fields in
  let* outcome = outcome_of_json marker (path @ [ "outcome" ]) outcome_json in
  let* certificate_json = field path "certificate" fields in
  let* certificate =
    certificate_option_of_json (path @ [ "certificate" ]) certificate_json
  in
  match marker_result ~marker ~outcome ~certificate with
  | Ok result -> Ok result
  | Error _ ->
      malformed path "marker outcome does not match marker identity or channel"

let catalogue_field_to_json (name, leaf) =
  `Assoc [ ("name", `String name); ("leaf", identity_to_json leaf) ]

let catalogue_field_of_json path json =
  let* fields = as_object path json in
  let* name_json = field path "name" fields in
  let* name = as_string (path @ [ "name" ]) name_json in
  let* leaf_json = field path "leaf" fields in
  let* leaf = identity_of_json (path @ [ "leaf" ]) leaf_json in
  Ok (name, leaf)

let catalogue_to_json catalogue =
  `Assoc
    [
      ("identity", identity_to_json catalogue.identity);
      ("union", identity_to_json catalogue.union);
      ("fields", `List (List.map catalogue_field_to_json catalogue.fields));
    ]

let catalogue_of_json path json =
  let* fields = as_object path json in
  let* identity_json = field path "identity" fields in
  let* identity = identity_of_json (path @ [ "identity" ]) identity_json in
  let* union_json = field path "union" fields in
  let* union = identity_of_json (path @ [ "union" ]) union_json in
  let* fields_json = field path "fields" fields in
  let* fields =
    decode_list catalogue_field_of_json (path @ [ "fields" ]) fields_json
  in
  match catalogue ~identity ~union ~fields with
  | Ok catalogue -> Ok catalogue
  | Error (Empty_catalogue _) ->
      malformed (path @ [ "fields" ]) "catalogue field partition is empty"
  | Error (Empty_catalogue_field _) ->
      malformed (path @ [ "fields" ]) "catalogue field name is empty"
  | Error (Duplicate_catalogue_field_name { name; _ }) ->
      malformed (path @ [ "fields" ])
        (Printf.sprintf "duplicate catalogue field name %S" name)
  | Error (Duplicate_catalogue_leaf { leaf; _ }) ->
      malformed (path @ [ "fields" ])
        (Printf.sprintf "duplicate catalogue leaf %S" (Identity.to_string leaf))
  | Error _ -> malformed path "invalid catalogue"

let response_to_json (response : response) =
  `Assoc
    [
      ("protocol", `String "hamlet-subtractor-resolution");
      ("version", `Int version);
      ("request_id", `String response.request_id);
      ("context_fingerprint", `String response.context_fingerprint);
      ("ast_digest", `String response.ast_digest);
      ("results", `List (List.map marker_result_to_json response.results));
      ("catalogues", `List (List.map catalogue_to_json response.catalogues));
      ( "generic_attachments",
        `List (List.map generic_attachment_to_json response.generic_attachments)
      );
    ]

let encode response = Yojson.Basic.to_string (response_to_json response)

let response_of_json json =
  let path = [] in
  let* fields = as_object path json in
  let* protocol_json = field path "protocol" fields in
  let* protocol = as_string [ "protocol" ] protocol_json in
  let* () =
    if protocol = "hamlet-subtractor-resolution" then Ok ()
    else malformed [ "protocol" ] "unexpected protocol name"
  in
  let* version_json = field path "version" fields in
  let* actual = as_int [ "version" ] version_json in
  let* () =
    if actual = version then Ok ()
    else Error (Version_mismatch { expected = version; actual })
  in
  let* request_id_json = field path "request_id" fields in
  let* request_id = as_string [ "request_id" ] request_id_json in
  let* context_json = field path "context_fingerprint" fields in
  let* context_fingerprint = as_string [ "context_fingerprint" ] context_json in
  let* ast_digest_json = field path "ast_digest" fields in
  let* ast_digest = as_string [ "ast_digest" ] ast_digest_json in
  let* results_json = field path "results" fields in
  let* results = decode_list marker_result_of_json [ "results" ] results_json in
  let* catalogues_json = field path "catalogues" fields in
  let* catalogues =
    decode_list catalogue_of_json [ "catalogues" ] catalogues_json
  in
  let generic_attachments_json =
    optional_field "generic_attachments" ~default:(`List []) fields
  in
  let* generic_attachments =
    decode_list generic_attachment_of_json [ "generic_attachments" ]
      generic_attachments_json
  in
  match
    response ~catalogues ~generic_attachments ~request_id ~context_fingerprint
      ~ast_digest results
  with
  | Ok response -> Ok response
  | Error Empty_request_id ->
      malformed [ "request_id" ] "request identity must not be empty"
  | Error Empty_context_fingerprint ->
      malformed [ "context_fingerprint" ]
        "context fingerprint must not be empty"
  | Error Empty_ast_digest ->
      malformed [ "ast_digest" ] "AST digest must not be empty"
  | Error (Duplicate_marker marker) ->
      malformed [ "results" ]
        (Printf.sprintf "duplicate marker %S" (Marker.id_to_string marker))
  | Error (Conflicting_catalogue identity) ->
      malformed [ "catalogues" ]
        (Printf.sprintf "conflicting catalogue %S"
           (Identity.to_string identity))
  | Error (Duplicate_generic_attachment id) ->
      malformed [ "generic_attachments" ]
        (Printf.sprintf "duplicate generic attachment %S" id)
  | Error _ -> malformed [ "results" ] "invalid marker results"

let decode input =
  try response_of_json (Yojson.Basic.from_string input)
  with Yojson.Json_error message -> malformed [] message
