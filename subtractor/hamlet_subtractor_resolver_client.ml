module Compiler_config = Config
module Compiler_location = Location
module Compiler_pparse = Pparse

open Ppxlib

module Protocol = Hamlet_subtractor_core.Protocol

let () = Hamlet_subtractor_resolver_ready.built

type error =
  | Ast_serialization_failed of string
  | Protocol_construction_failed of Protocol.construction_error
  | Transport_failed of Hamlet_subtractor_resolver_transport.error

type resolution = {
  engine : Hamlet_subtractor_engine.t;
  generic_attachments : Protocol.generic_attachment list;
}

let remove_noerr path = try Sys.remove path with Sys_error _ -> ()

let with_serialized_probe ~source_file structure f =
  try
    let raw_path, channel =
      Filename.open_temp_file "hamlet-subtractor-probe-" ".ast"
    in
    let normalized_path = ref None in
    Fun.protect
      ~finally:(fun () ->
        close_out_noerr channel;
        remove_noerr raw_path;
        Option.iter remove_noerr !normalized_path)
      (fun () ->
        let path =
          if Filename.is_relative raw_path then
            Filename.concat (Sys.getcwd ()) raw_path
          else raw_path
        in
        normalized_path := Some path;
        close_out channel;
        let compiler_structure =
          Selected_ast.to_ocaml Selected_ast.Type.Structure structure
        in
        let previous_input_name = !Compiler_location.input_name in
        Fun.protect
          ~finally:(fun () ->
            Compiler_location.input_name := previous_input_name)
          (fun () ->
            Compiler_location.input_name := source_file;
            Compiler_pparse.write_ast Compiler_pparse.Structure path
              compiler_structure);
        let stats = Unix.stat path in
        let descriptor : Protocol.ast_descriptor =
          {
            path;
            input_name = source_file;
            magic = Compiler_config.ast_impl_magic_number;
            digest = Digest.file path |> Digest.to_hex;
            byte_length = stats.st_size;
          }
        in
        Ok (f descriptor))
  with exn -> Error (Ast_serialization_failed (Printexc.to_string exn))

let core_marker (marker : Hamlet_subtractor_probe.marker) =
  let id =
    Hamlet_subtractor_core.Marker.id_of_string marker.id |> Result.get_ok
  in
  let loc = marker.loc in
  let span =
    Hamlet_subtractor_core.Source_span.make ~file:loc.loc_start.pos_fname
      ~start_offset:loc.loc_start.pos_cnum ~end_offset:loc.loc_end.pos_cnum
      ~start_line:loc.loc_start.pos_lnum
      ~start_column:(loc.loc_start.pos_cnum - loc.loc_start.pos_bol)
      ~end_line:loc.loc_end.pos_lnum
      ~end_column:(loc.loc_end.pos_cnum - loc.loc_end.pos_bol)
    |> Result.get_ok
  in
  let kind =
    match marker.kind with
    | Hamlet_subtractor_probe.Error_propagation ->
        Hamlet_subtractor_core.Kind.Error
    | Hamlet_subtractor_probe.Requirement_propagation ->
        Hamlet_subtractor_core.Kind.Requirement
  in
  Hamlet_subtractor_core.Marker.make ~id ~kind ~span

let request_id ~context_fingerprint descriptor =
  Printf.sprintf "%s\000%s\000%d\000%.17g" context_fingerprint
    descriptor.Protocol.path (Unix.getpid ()) (Unix.gettimeofday ())
  |> Digest.string
  |> Digest.to_hex

let synthetic_unit context_fingerprint =
  "Hamlet_subtractor_probe_" ^ String.sub context_fingerprint 0 16

let make_request
    ~generic_expectations
    ~tool_name
    ~source_file
    prepared
    descriptor =
  let context =
    Hamlet_subtractor_compiler_compat.request_context ~source_file
      prepared.Hamlet_subtractor_probe.probe_structure
  in
  let context_fingerprint = context.context_fingerprint in
  let request =
    if generic_expectations = [] then Protocol.request
    else Protocol.request_with_generic_expectations ~generic_expectations
  in
  request
    ~request_id:(request_id ~context_fingerprint descriptor)
    ~source_file ~tool_name ~probe_ast:descriptor
    ~probe_unit:(Protocol.Synthetic_unit (synthetic_unit context_fingerprint))
    ~tool_context:context.tool_context ~context_fingerprint
    ~include_dirs:context.include_dirs
    ~hidden_include_dirs:context.hidden_include_dirs
    ~visible_paths:context.visible_paths ~hidden_paths:context.hidden_paths
    ~opens:context.opens ~package_mode:context.package_mode
    ~compiler_flags:context.compiler_flags
    ~expected_markers:
      (List.map core_marker prepared.Hamlet_subtractor_probe.markers)

let resolve_elaboration
    ?program
    ?limits
    ?(generic_expectations = [])
    ~tool_name
    ~source_file
    prepared =
  match
    with_serialized_probe ~source_file
      prepared.Hamlet_subtractor_probe.probe_structure (fun descriptor ->
        match
          make_request ~generic_expectations ~tool_name ~source_file prepared
            descriptor
        with
        | Error error -> Error (Protocol_construction_failed error)
        | Ok request ->
            let response =
              match program with
              | None -> Hamlet_subtractor_resolver_transport.run ?limits request
              | Some program ->
                  Hamlet_subtractor_resolver_transport.run_program ?limits
                    ~program ~arguments:[||] request
            in
            response
            |> Result.map (fun response ->
                {
                  engine = Hamlet_subtractor_engine.of_response response;
                  generic_attachments = Protocol.generic_attachments response;
                })
            |> Result.map_error (fun error -> Transport_failed error))
  with
  | Error _ as error -> error
  | Ok result -> result

let resolve_prepared ?program ?limits ~tool_name ~source_file prepared =
  resolve_elaboration ?program ?limits ~tool_name ~source_file prepared
  |> Result.map (fun resolution -> resolution.engine)

let construction_error_message error =
  let open Protocol in
  match error with
  | Outcome_marker_mismatch -> "outcome marker mismatch"
  | Outcome_kind_mismatch _ -> "outcome channel mismatch"
  | Missing_resolution_certificate -> "missing resolution certificate"
  | Unexpected_resolution_certificate -> "unexpected refusal certificate"
  | Resolution_certificate_mismatch -> "resolution certificate mismatch"
  | Empty_request_id -> "empty request identity"
  | Empty_context_fingerprint -> "empty compilation context fingerprint"
  | Empty_source_file -> "empty source filename"
  | Empty_tool_name -> "empty PPX tool name"
  | Empty_ast_path | Relative_ast_path -> "invalid binary AST path"
  | Empty_ast_input_name -> "empty binary AST input name"
  | Empty_ast_magic -> "empty binary AST magic"
  | Empty_ast_digest -> "empty binary AST digest"
  | Invalid_ast_byte_length _ -> "invalid binary AST byte length"
  | Empty_synthetic_unit -> "empty synthetic probe unit"
  | Empty_tool_version field -> "empty tool version " ^ field
  | Invalid_catalogue_schema_version _ -> "invalid catalogue schema version"
  | Empty_for_pack -> "empty package name"
  | Duplicate_marker id ->
      "duplicate marker " ^ Hamlet_subtractor_core.Marker.id_to_string id
  | Empty_catalogue identity ->
      "empty catalogue " ^ Hamlet_subtractor_core.Identity.to_string identity
  | Empty_catalogue_field identity ->
      "empty catalogue field "
      ^ Hamlet_subtractor_core.Identity.to_string identity
  | Duplicate_catalogue_field_name { name; _ } ->
      "duplicate catalogue field " ^ name
  | Duplicate_catalogue_leaf { leaf; _ } ->
      "duplicate catalogue leaf "
      ^ Hamlet_subtractor_core.Identity.to_string leaf
  | Conflicting_catalogue identity ->
      "conflicting catalogue "
      ^ Hamlet_subtractor_core.Identity.to_string identity
  | Empty_generic_attachment_id -> "empty generic attachment identity"
  | Empty_generic_attachment_payload id ->
      "empty generic attachment payload " ^ id
  | Generic_attachment_payload_too_large { id; _ } ->
      "oversized generic attachment payload " ^ id
  | Duplicate_generic_expectation id ->
      "duplicate generic attachment expectation " ^ id
  | Duplicate_generic_attachment id -> "duplicate generic attachment " ^ id

let message = function
  | Ast_serialization_failed detail ->
      "could not serialize the location-preserving probe AST: " ^ detail
  | Protocol_construction_failed error ->
      "could not construct the resolver request: "
      ^ construction_error_message error
  | Transport_failed error -> Hamlet_subtractor_resolver_transport.message error
