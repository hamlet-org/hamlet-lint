type refusal =
  | Dependency_scan
  | Unsupported_tool of string
  | Typing_failed of typing_failure
  | Probe_lookup_failed of Hamlet_subtractor_probe.lookup_error list
  | Evidence_failed of Hamlet_subtractor_compiler_evidence.refusal
  | Generic_evidence_failed of
      Hamlet_subtractor_compiler_evidence.generic_refusal
  | Request_context_mismatch of {
      field : string;
      expected : string;
      actual : string;
    }
  | Probe_ast_failed of string
  | Protocol_construction_failed of
      Hamlet_subtractor_core.Protocol.construction_error
  | Protocol_correlation_failed of
      Hamlet_subtractor_core.Protocol.correlation_error

and typing_failure = { message : string; location : Location.t option }

type observation = {
  structure_items : int;
  links : Hamlet_subtractor_probe.typed_observation list;
}

type request_context = {
  context_fingerprint : string;
  include_dirs : string list;
  hidden_include_dirs : string list;
  visible_paths : string list;
  hidden_paths : string list;
  opens : string list;
  package_mode : Hamlet_subtractor_core.Protocol.package_mode;
  compiler_flags : Hamlet_subtractor_core.Protocol.compiler_flags;
  tool_context : Hamlet_subtractor_core.Protocol.tool_context;
}

module Protocol = Hamlet_subtractor_core.Protocol

let exception_message exn =
  match Location.error_of_exn exn with
  | Some (`Ok report) -> Format.asprintf "%a" Location.print_report report
  | Some `Already_displayed -> "compiler error was already displayed"
  | None -> Printexc.to_string exn

let typing_failure exn =
  match Location.error_of_exn exn with
  | Some (`Ok report) ->
      {
        message = Format.asprintf "%a" Location.print_report report;
        location = Some report.main.loc;
      }
  | Some `Already_displayed ->
      { message = "compiler error was already displayed"; location = None }
  | None -> { message = Printexc.to_string exn; location = None }

let restore_ppx_context ~tool_name structure =
  structure
  |> Ast_mapper.add_ppx_context_str ~tool_name
  |> Ast_mapper.drop_ppx_context_str ~restore:true

let compilation_unit ~unit_name ~source_file =
  Unit_info.make ~check_modname:false ~source_file Unit_info.Impl unit_name

let paths_are_empty (paths : Load_path.paths) =
  paths.visible = [] && paths.hidden = []

let init_probe_path restored_paths =
  (* Merlin can restore flags without materialising the corresponding load
     path. Rebuild it first, then prefer an exact populated path captured from
     the PPX context. *)
  Compmisc.init_path ();
  let rebuilt_paths = Load_path.get_paths () in
  let paths : Load_path.paths =
    if paths_are_empty restored_paths then rebuilt_paths else restored_paths
  in
  Load_path.init ~auto_include:Compmisc.auto_include ~visible:paths.visible
    ~hidden:paths.hidden;
  Env.reset_cache ()

let type_in_fresh_store
    ~unit_name
    ~source_file
    ~restored_paths
    structure
    ~normalize =
  let store = Local_store.fresh () in
  Local_store.with_store store @@ fun () ->
  init_probe_path restored_paths;
  Env.set_current_unit (compilation_unit ~unit_name ~source_file);
  Typecore.reset_delayed_checks ();
  Env.reset_required_globals ();
  let type_snapshot = Btype.snapshot () in
  let warning_state = Warnings.backup () in
  let saved_types = Cmt_format.get_saved_types () in
  Cmt_format.clear ();
  Fun.protect
    ~finally:(fun () ->
      Typecore.reset_delayed_checks ();
      Env.reset_required_globals ();
      Btype.backtrack type_snapshot;
      Cmt_format.set_saved_types saved_types;
      Warnings.restore warning_state)
    (fun () ->
      Warnings.without_warnings @@ fun () ->
      let initial_env = Compmisc.initial_env () in
      let typed, _, _, _, _ = Typemod.type_structure initial_env structure in
      Typecore.force_delayed_checks ();
      normalize typed)

let inspect_probe ~tool_name ~source_file structure =
  if String.equal tool_name "ocamldep" then Error Dependency_scan
  else
    try
      let structure =
        Ppxlib.Selected_ast.to_ocaml Ppxlib.Selected_ast.Type.Structure
          structure
        |> restore_ppx_context ~tool_name
      in
      let restored_paths = Load_path.get_paths () in
      type_in_fresh_store ~unit_name:"Hamlet_subtractor_inspection" ~source_file
        ~restored_paths structure ~normalize:(fun typed ->
          match Hamlet_subtractor_probe.observe_typedtree typed with
          | Ok links ->
              Ok { structure_items = List.length typed.str_items; links }
          | Error errors -> Error (Probe_lookup_failed errors))
    with exn -> Error (Typing_failed (typing_failure exn))

let captured_paths () =
  let saved = Load_path.get_paths () in
  if not (paths_are_empty saved) then saved
  else
    Fun.protect
      ~finally:(fun () ->
        Load_path.init ~auto_include:Compmisc.auto_include
          ~visible:saved.visible ~hidden:saved.hidden;
        Env.reset_cache ())
      (fun () ->
        Compmisc.init_path ();
        Load_path.get_paths ())

let semantic_context_fingerprint
    ~source_file
    ~structure
    ~tool_context
    ~include_dirs
    ~hidden_include_dirs
    ~visible_paths
    ~hidden_paths
    ~opens
    ~package_mode
    ~compiler_flags =
  Marshal.to_string
    ( source_file,
      structure,
      tool_context,
      include_dirs,
      hidden_include_dirs,
      visible_paths,
      hidden_paths,
      opens,
      package_mode,
      compiler_flags )
    [ Marshal.No_sharing ]
  |> Digest.string
  |> Digest.to_hex

let request_context ~source_file structure =
  let paths = captured_paths () in
  let include_dirs = !Clflags.include_dirs in
  let hidden_include_dirs = !Clflags.hidden_include_dirs in
  let opens = !Clflags.open_modules in
  let package_mode =
    match !Clflags.for_package with
    | None -> Protocol.Standalone
    | Some pack -> Protocol.For_pack pack
  in
  let compiler_flags =
    Protocol.
      {
        debug = !Clflags.debug;
        principal = !Clflags.principal;
        recursive_types = !Clflags.recursive_types;
        alias_dependencies = not !Clflags.no_alias_deps;
        use_threads = !Clflags.use_threads;
        unboxed_types = !Clflags.unboxed_types;
      }
  in
  let tool_context =
    Protocol.
      {
        ocaml_version = Sys.ocaml_version;
        hamlet_subtractor_version = Hamlet_subtractor_version.value;
        resolver_version = Hamlet_subtractor_version.value;
        catalogue_schema_version = 1;
      }
  in
  let compiler_structure =
    Ppxlib.Selected_ast.to_ocaml Ppxlib.Selected_ast.Type.Structure structure
  in
  let context_fingerprint =
    semantic_context_fingerprint ~source_file ~structure:compiler_structure
      ~tool_context ~include_dirs ~hidden_include_dirs
      ~visible_paths:paths.visible ~hidden_paths:paths.hidden ~opens
      ~package_mode ~compiler_flags
  in
  {
    context_fingerprint;
    include_dirs;
    hidden_include_dirs;
    visible_paths = paths.visible;
    hidden_paths = paths.hidden;
    opens;
    package_mode;
    compiler_flags;
    tool_context;
  }

let synthetic_unit context_digest =
  "Hamlet_subtractor_probe_" ^ String.sub context_digest 0 16

type elaboration = {
  engine : Hamlet_subtractor_engine.t;
  generic_definitions :
    Hamlet_subtractor_compiler_evidence.generic_definition list;
  generic_calls : Hamlet_subtractor_compiler_evidence.generic_call list;
}

let elaborate_typedtree ~context_digest typed =
  match
    Hamlet_subtractor_compiler_evidence.elaborate_typedtree ~context_digest
      typed
  with
  | Error refusal -> Error (Evidence_failed refusal)
  | Ok engine -> (
      match
        Hamlet_subtractor_compiler_evidence.generic_definitions_typedtree
          ~context_digest typed
      with
      | Error refusal -> Error (Generic_evidence_failed refusal)
      | Ok generic_definitions -> (
          match
            Hamlet_subtractor_compiler_evidence.generic_calls_typedtree
              ~context_digest ~definitions:generic_definitions typed
          with
          | Error refusal -> Error (Generic_evidence_failed refusal)
          | Ok generic_calls ->
              Ok { engine; generic_definitions; generic_calls }))

let elaborate_prepared ~tool_name ~source_file prepared =
  if String.equal tool_name "ocamldep" then Error Dependency_scan
  else
    try
      let structure =
        Ppxlib.Selected_ast.to_ocaml Ppxlib.Selected_ast.Type.Structure
          prepared.Hamlet_subtractor_probe.probe_structure
        |> restore_ppx_context ~tool_name
      in
      let context =
        request_context ~source_file
          prepared.Hamlet_subtractor_probe.probe_structure
      in
      let restored_paths : Load_path.paths =
        { visible = context.visible_paths; hidden = context.hidden_paths }
      in
      let context_digest = context.context_fingerprint in
      type_in_fresh_store ~unit_name:(synthetic_unit context_digest)
        ~source_file ~restored_paths structure ~normalize:(fun typed ->
          elaborate_typedtree ~context_digest typed)
    with exn -> Error (Typing_failed (typing_failure exn))

let resolve_prepared ~tool_name ~source_file prepared =
  elaborate_prepared ~tool_name ~source_file prepared
  |> Result.map (fun elaboration -> elaboration.engine)
let request_context_mismatch ~field ~expected ~actual =
  Error (Request_context_mismatch { field; expected; actual })

let validate_request_tool request =
  match Protocol.tool_name request with
  | "ocamldep" -> Error Dependency_scan
  | ("dune" | "ppx_driver" | "ppxlib_driver") as tool ->
      Error (Unsupported_tool tool)
  | _ -> Ok ()

let validate_request_context request =
  let context = Protocol.tool_context request in
  if not (String.equal context.ocaml_version Sys.ocaml_version) then
    request_context_mismatch ~field:"ocaml_version" ~expected:Sys.ocaml_version
      ~actual:context.ocaml_version
  else if
    not
      (String.equal context.hamlet_subtractor_version
         Hamlet_subtractor_version.value)
  then
    request_context_mismatch ~field:"hamlet_subtractor_version"
      ~expected:Hamlet_subtractor_version.value
      ~actual:context.hamlet_subtractor_version
  else if
    not (String.equal context.resolver_version Hamlet_subtractor_version.value)
  then
    request_context_mismatch ~field:"resolver_version"
      ~expected:Hamlet_subtractor_version.value ~actual:context.resolver_version
  else if context.catalogue_schema_version <> 1 then
    request_context_mismatch ~field:"catalogue_schema_version" ~expected:"1"
      ~actual:(string_of_int context.catalogue_schema_version)
  else Ok ()

type saved_flags = {
  include_dirs : string list;
  hidden_include_dirs : string list;
  open_modules : string list;
  for_package : string option;
  debug : bool;
  principal : bool;
  recursive_types : bool;
  no_alias_deps : bool;
  use_threads : bool;
  unboxed_types : bool;
}

let save_flags () =
  {
    include_dirs = !Clflags.include_dirs;
    hidden_include_dirs = !Clflags.hidden_include_dirs;
    open_modules = !Clflags.open_modules;
    for_package = !Clflags.for_package;
    debug = !Clflags.debug;
    principal = !Clflags.principal;
    recursive_types = !Clflags.recursive_types;
    no_alias_deps = !Clflags.no_alias_deps;
    use_threads = !Clflags.use_threads;
    unboxed_types = !Clflags.unboxed_types;
  }

let restore_flags (saved : saved_flags) =
  Clflags.include_dirs := saved.include_dirs;
  Clflags.hidden_include_dirs := saved.hidden_include_dirs;
  Clflags.open_modules := saved.open_modules;
  Clflags.for_package := saved.for_package;
  Clflags.debug := saved.debug;
  Clflags.principal := saved.principal;
  Clflags.recursive_types := saved.recursive_types;
  Clflags.no_alias_deps := saved.no_alias_deps;
  Clflags.use_threads := saved.use_threads;
  Clflags.unboxed_types := saved.unboxed_types

let apply_request_flags request =
  let flags = Protocol.compiler_flags request in
  Clflags.include_dirs := Protocol.include_dirs request;
  Clflags.hidden_include_dirs := Protocol.hidden_include_dirs request;
  Clflags.open_modules := Protocol.opens request;
  (Clflags.for_package :=
     match Protocol.package_mode request with
     | Protocol.Standalone -> None
     | Protocol.For_pack pack -> Some pack);
  Clflags.debug := flags.debug;
  Clflags.principal := flags.principal;
  Clflags.recursive_types := flags.recursive_types;
  Clflags.no_alias_deps := not flags.alias_dependencies;
  Clflags.use_threads := flags.use_threads;
  Clflags.unboxed_types := flags.unboxed_types

let with_request_context request f =
  let saved_flags = save_flags () in
  let saved_warnings = Warnings.backup () in
  let saved_paths = Load_path.get_paths () in
  Fun.protect
    ~finally:(fun () ->
      restore_flags saved_flags;
      Warnings.restore saved_warnings;
      Load_path.init ~auto_include:Compmisc.auto_include
        ~visible:saved_paths.visible ~hidden:saved_paths.hidden;
      Env.reset_cache ())
    (fun () ->
      apply_request_flags request;
      f ())

let maximum_ast_bytes = 64 * 1024 * 1024

let validate_ast_file (descriptor : Protocol.ast_descriptor) =
  try
    if not (String.equal descriptor.Protocol.magic Config.ast_impl_magic_number)
    then
      Error (Probe_ast_failed "binary AST magic does not match this compiler")
    else
      let stats = Unix.stat descriptor.path in
      if stats.st_kind <> Unix.S_REG then
        Error (Probe_ast_failed "binary AST path is not a regular file")
      else if stats.st_size <> descriptor.byte_length then
        Error (Probe_ast_failed "binary AST byte length changed")
      else if stats.st_size > maximum_ast_bytes then
        Error (Probe_ast_failed "binary AST exceeds the resolver limit")
      else
        let digest = Digest.file descriptor.path |> Digest.to_hex in
        if not (String.equal digest descriptor.digest) then
          Error (Probe_ast_failed "binary AST digest changed")
        else Ok ()
  with exn -> Error (Probe_ast_failed (exception_message exn))

let read_probe request =
  let descriptor = Protocol.probe_ast request in
  match validate_ast_file descriptor with
  | Error _ as error -> error
  | Ok () -> (
      try
        let structure = Pparse.read_ast Pparse.Structure descriptor.path in
        if not (String.equal !Location.input_name descriptor.input_name) then
          Error
            (Probe_ast_failed
               "binary AST input name does not match its descriptor")
        else if
          not
            (String.equal descriptor.input_name (Protocol.source_file request))
        then
          Error
            (Probe_ast_failed
               "binary AST input name does not match the source context")
        else Ok structure
      with exn -> Error (Probe_ast_failed (exception_message exn)))

let validate_request_semantics request structure =
  let fingerprint =
    semantic_context_fingerprint
      ~source_file:(Protocol.source_file request)
      ~structure
      ~tool_context:(Protocol.tool_context request)
      ~include_dirs:(Protocol.include_dirs request)
      ~hidden_include_dirs:(Protocol.hidden_include_dirs request)
      ~visible_paths:(Protocol.visible_paths request)
      ~hidden_paths:(Protocol.hidden_paths request)
      ~opens:(Protocol.opens request)
      ~package_mode:(Protocol.package_mode request)
      ~compiler_flags:(Protocol.compiler_flags request)
  in
  let claimed = Protocol.request_context_fingerprint request in
  if not (String.equal fingerprint claimed) then
    request_context_mismatch ~field:"context_fingerprint" ~expected:fingerprint
      ~actual:claimed
  else
    let expected_unit = synthetic_unit fingerprint in
    let actual_unit =
      match Protocol.probe_unit request with
      | Protocol.Synthetic_unit name -> name
    in
    if String.equal expected_unit actual_unit then Ok ()
    else
      request_context_mismatch ~field:"probe_unit" ~expected:expected_unit
        ~actual:actual_unit

let marker_results engine =
  let resolved = Hamlet_subtractor_engine.resolved_values engine in
  let certificate_for marker =
    List.find_map
      (fun (candidate, value) ->
        if Hamlet_subtractor_core.Marker.equal marker candidate then
          Some value.Hamlet_subtractor_engine.certificate
        else None)
      resolved
  in
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | (marker, outcome) :: rest -> (
        let certificate =
          match outcome with
          | Protocol.Resolved _ -> certificate_for marker
          | Protocol.Refused _ -> None
        in
        match Protocol.marker_result ~marker ~outcome ~certificate with
        | Ok result -> loop (result :: accumulated) rest
        | Error error -> Error (Protocol_construction_failed error))
  in
  loop [] (Hamlet_subtractor_engine.outcomes engine)

let generic_attachments definitions calls =
  let rec definitions_loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | (definition : Hamlet_subtractor_compiler_evidence.generic_definition)
      :: rest -> (
        match
          Hamlet_subtractor_core.Generic_resolution.encode_definition
            definition.contract
        with
        | Error _ ->
            Error
              (Protocol_construction_failed
                 (Protocol.Empty_generic_attachment_payload
                    definition.attachment_id))
        | Ok payload -> (
            match
              Protocol.generic_attachment ~id:definition.attachment_id
                ~kind:Protocol.Definition ~payload
            with
            | Error error -> Error (Protocol_construction_failed error)
            | Ok attachment -> definitions_loop (attachment :: accumulated) rest
            ))
  in
  let rec calls_loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | (call : Hamlet_subtractor_compiler_evidence.generic_call) :: rest -> (
        match
          Hamlet_subtractor_core.Generic_resolution.encode_call
            ~contract:call.contract ~input:call.input
        with
        | Error _ ->
            Error
              (Protocol_construction_failed
                 (Protocol.Empty_generic_attachment_payload call.attachment_id))
        | Ok payload -> (
            match
              Protocol.generic_attachment ~id:call.attachment_id
                ~kind:Protocol.Call ~payload
            with
            | Error error -> Error (Protocol_construction_failed error)
            | Ok attachment -> calls_loop (attachment :: accumulated) rest))
  in
  match definitions_loop [] definitions with
  | Error _ as error -> error
  | Ok definition_attachments ->
      calls_loop [] calls
      |> Result.map (fun call_attachments ->
          definition_attachments @ call_attachments)

let response_for_elaboration request elaboration =
  let engine = elaboration.engine in
  match marker_results engine with
  | Error _ as error -> error
  | Ok results -> (
      let engine_catalogues = Hamlet_subtractor_engine.catalogues engine in
      let definition_catalogues =
        elaboration.generic_definitions
        |> List.concat_map
             (fun
               (definition :
                 Hamlet_subtractor_compiler_evidence.generic_definition)
             -> definition.catalogues)
      in
      let call_catalogues =
        elaboration.generic_calls
        |> List.concat_map
             (fun (call : Hamlet_subtractor_compiler_evidence.generic_call) ->
               call.catalogues)
      in
      let catalogues =
        engine_catalogues @ definition_catalogues @ call_catalogues
        |> List.sort_uniq Hamlet_subtractor_catalogue.compare
        |> List.map Hamlet_subtractor_catalogue.to_protocol
      in
      match
        generic_attachments elaboration.generic_definitions
          elaboration.generic_calls
      with
      | Error _ as error -> error
      | Ok generic_attachments -> (
          let context_fingerprint =
            Protocol.request_context_fingerprint request
          in
          let descriptor = Protocol.probe_ast request in
          match
            Protocol.response ~catalogues ~generic_attachments
              ~request_id:(Protocol.request_id request)
              ~context_fingerprint ~ast_digest:descriptor.digest results
          with
          | Error error -> Error (Protocol_construction_failed error)
          | Ok response -> (
              match Protocol.validate_response ~request ~response with
              | Ok () -> Ok response
              | Error error -> Error (Protocol_correlation_failed error))))

let resolve_request request =
  match validate_request_tool request with
  | Error _ as error -> error
  | Ok () -> (
      match validate_request_context request with
      | Error _ as error -> error
      | Ok () -> (
          match read_probe request with
          | Error _ as error -> error
          | Ok structure -> (
              match validate_request_semantics request structure with
              | Error _ as error -> error
              | Ok () -> (
                  try
                    with_request_context request @@ fun () ->
                    let paths : Load_path.paths =
                      {
                        visible = Protocol.visible_paths request;
                        hidden = Protocol.hidden_paths request;
                      }
                    in
                    let unit_name =
                      synthetic_unit
                        (Protocol.request_context_fingerprint request)
                    in
                    type_in_fresh_store ~unit_name
                      ~source_file:(Protocol.source_file request)
                      ~restored_paths:paths structure ~normalize:(fun typed ->
                        elaborate_typedtree
                          ~context_digest:
                            (Protocol.request_context_fingerprint request)
                          typed)
                    |> function
                    | Error _ as error -> error
                    | Ok elaboration ->
                        response_for_elaboration request elaboration
                  with exn -> Error (Typing_failed (typing_failure exn))))))
