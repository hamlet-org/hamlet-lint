module Compiler_pprintast = Pprintast
module Compiler_parsetree = Parsetree
module Compiler_pparse = Pparse
module Compiler_config = Config
module Compiler_clflags = Clflags
module Compiler_compmisc = Compmisc
module Compiler_env = Env
module Compiler_load_path = Load_path

open Ppxlib
open Hamlet_subtractor_core

let parse ?(source_file = "resolver_parity.ml") source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf source_file;
  Parse.implementation lexbuf

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.fail (label ^ " unexpectedly failed")

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else loop (index + 1)
  in
  loop 0

let find_hamlet_cmi_directory () =
  match Sys.getenv_opt "OPAM_SWITCH_PREFIX" with
  | Some prefix ->
      let cmi = Filename.concat prefix "lib/hamlet/hamlet.cmi" in
      if Sys.file_exists cmi then Filename.dirname cmi
      else Alcotest.failf "cannot locate installed Hamlet CMI at %s" cmi
  | None -> Alcotest.fail "OPAM_SWITCH_PREFIX is required to locate Hamlet"

let find_test_services_cmi_directory () =
  let relative = ".hamlet_test_services.objs/byte/hamlet_test_services.cmi" in
  let executable_directory = Filename.dirname Sys.executable_name in
  let candidates =
    [
      Filename.concat
        (Filename.dirname (Filename.dirname executable_directory))
        (Filename.concat "test/support" relative);
      Filename.concat (Sys.getcwd ())
        (Filename.concat "_build/default/test/support" relative);
      Filename.concat (Sys.getcwd ()) (Filename.concat "test/support" relative);
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some cmi -> Filename.dirname cmi
  | None -> Alcotest.fail "cannot locate Hamlet test services CMI fixture"

let with_include_directory directory f =
  let previous_include_dirs = !Compiler_clflags.include_dirs in
  let previous_paths : Compiler_load_path.paths =
    Compiler_load_path.get_paths ()
  in
  Fun.protect
    ~finally:(fun () ->
      Compiler_clflags.include_dirs := previous_include_dirs;
      Compiler_load_path.init ~auto_include:Compiler_compmisc.auto_include
        ~visible:previous_paths.visible ~hidden:previous_paths.hidden;
      Compiler_env.reset_cache ())
    (fun () ->
      Compiler_clflags.include_dirs := directory :: previous_include_dirs;
      Compiler_compmisc.init_path ();
      f ())

let with_hamlet f = with_include_directory (find_hamlet_cmi_directory ()) f

let with_test_services f =
  with_hamlet @@ fun () ->
  with_include_directory (find_test_services_cmi_directory ()) f

let test_binary_ast_preserves_locations () =
  let source_file = "live-unsaved-buffer.ml" in
  let structure = parse ~source_file "\n\nlet answer = 42\n" in
  match
    Hamlet_subtractor_resolver_client.with_serialized_probe ~source_file
      structure (fun descriptor ->
        let before = Unix.stat descriptor.path in
        Alcotest.(check int)
          "descriptor length" before.st_size descriptor.byte_length;
        Alcotest.(check string)
          "descriptor digest" descriptor.digest
          (Digest.file descriptor.path |> Digest.to_hex);
        Compiler_pparse.read_ast Compiler_pparse.Structure descriptor.path)
  with
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  | Ok
      [
        {
          Compiler_parsetree.pstr_desc =
            Compiler_parsetree.Pstr_value
              ( _,
                [
                  {
                    Compiler_parsetree.pvb_expr =
                      { Compiler_parsetree.pexp_loc = expression_location; _ };
                    _;
                  };
                ] );
          _;
        };
      ] ->
      Alcotest.(check string)
        "live filename" source_file expression_location.loc_start.pos_fname;
      Alcotest.(check int)
        "line preserved" 3 expression_location.loc_start.pos_lnum;
      Alcotest.(check int)
        "offset preserved" 15 expression_location.loc_start.pos_cnum
  | Ok _ -> Alcotest.fail "unexpected binary AST shape"

let peer () = Hamlet_subtractor_resolver_peer_ready.path

let fake_request
    ?(source_file = "fault.ml")
    ?(tool_name = "ocamlopt")
    ?descriptor
    () =
  let descriptor =
    Option.value descriptor
      ~default:
        ({
           path = "/tmp/hamlet-subtractor-unused.ast";
           input_name = source_file;
           magic = Compiler_config.ast_impl_magic_number;
           digest = "fault-ast";
           byte_length = 32;
         }
          : Protocol.ast_descriptor)
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
  let compiler_flags =
    Protocol.
      {
        debug = false;
        principal = false;
        recursive_types = false;
        alias_dependencies = true;
        use_threads = false;
        unboxed_types = false;
      }
  in
  Protocol.request ~request_id:"fault-request" ~source_file ~tool_name
    ~probe_ast:descriptor
    ~probe_unit:(Protocol.Synthetic_unit "Hamlet_subtractor_probe_fault")
    ~tool_context ~context_fingerprint:"fault-context" ~include_dirs:[]
    ~hidden_include_dirs:[] ~visible_paths:[] ~hidden_paths:[] ~opens:[]
    ~package_mode:Protocol.Standalone ~compiler_flags ~expected_markers:[]
  |> get_ok "fault request"

let run_peer mode ?limits ?request () =
  Hamlet_subtractor_resolver_transport.run_program ?limits ~program:(peer ())
    ~arguments:[| mode |]
    (Option.value request ~default:(fake_request ()))

let removed label path =
  Alcotest.(check bool) label false (Sys.file_exists path)

let test_serialized_probe_cleanup_on_success () =
  let path = ref None in
  let result =
    Hamlet_subtractor_resolver_client.with_serialized_probe
      ~source_file:"cleanup.ml" (parse "let value = 1") (fun descriptor ->
        path := Some descriptor.Protocol.path)
  in
  begin match result with
  | Ok () -> ()
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  end;
  removed "normal return removes AST" (Option.get !path)

let test_serialized_probe_cleanup_on_callback_exception () =
  let path = ref None in
  let result =
    Hamlet_subtractor_resolver_client.with_serialized_probe
      ~source_file:"cleanup.ml" (parse "let value = 1") (fun descriptor ->
        path := Some descriptor.Protocol.path;
        failwith "callback failure")
  in
  begin match result with
  | Error (Hamlet_subtractor_resolver_client.Ast_serialization_failed _) -> ()
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  | Ok _ -> Alcotest.fail "callback exception unexpectedly succeeded"
  end;
  removed "callback exception removes AST" (Option.get !path)

let test_serialized_probe_cleanup_on_child_timeout () =
  let path = ref None in
  let limits =
    Hamlet_subtractor_resolver_transport.
      { default_limits with timeout_seconds = 0.05 }
  in
  let result =
    Hamlet_subtractor_resolver_client.with_serialized_probe
      ~source_file:"cleanup.ml" (parse "let value = 1") (fun descriptor ->
        path := Some descriptor.Protocol.path;
        run_peer "timeout" ~limits ~request:(fake_request ~descriptor ()) ())
  in
  begin match result with
  | Ok (Error (Hamlet_subtractor_resolver_transport.Timeout _)) -> ()
  | Ok (Error error) ->
      Alcotest.fail (Hamlet_subtractor_resolver_transport.message error)
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  | Ok (Ok _) -> Alcotest.fail "timed out child unexpectedly succeeded"
  end;
  removed "child timeout removes AST" (Option.get !path)

let test_transport_crash () =
  match run_peer "crash" () with
  | Error (Hamlet_subtractor_resolver_transport.Process_failed _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected crash result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "crashing resolver succeeded"

let test_transport_timeout () =
  let limits =
    Hamlet_subtractor_resolver_transport.
      { default_limits with timeout_seconds = 0.05 }
  in
  match run_peer "timeout" ~limits () with
  | Error (Hamlet_subtractor_resolver_transport.Timeout _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected timeout result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "timed out resolver succeeded"

let test_transport_malformed_response () =
  match run_peer "malformed" () with
  | Error
      (Hamlet_subtractor_resolver_transport.Output_decode
         (Hamlet_subtractor_resolver_protocol.Malformed_output _)) ->
      ()
  | Error error ->
      Alcotest.fail
        ("unexpected malformed result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "malformed resolver response succeeded"

let test_transport_version_mismatch () =
  match run_peer "version" () with
  | Error
      (Hamlet_subtractor_resolver_transport.Output_decode
         (Hamlet_subtractor_resolver_protocol.Response_decode
            (Protocol.Version_mismatch { expected = 5; actual = 999 }))) ->
      ()
  | Error error ->
      Alcotest.fail
        ("unexpected version result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "mismatched resolver version succeeded"

let test_transport_context_mismatch () =
  match run_peer "context" () with
  | Error
      (Hamlet_subtractor_resolver_transport.Correlation
         (Protocol.Context_fingerprint_mismatch _)) ->
      ()
  | Error error ->
      Alcotest.fail
        ("unexpected context result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "mismatched resolver context succeeded"

let expect_correlation label mode predicate =
  match run_peer mode () with
  | Error (Hamlet_subtractor_resolver_transport.Correlation error)
    when predicate error ->
      ()
  | Error error ->
      Alcotest.fail
        (label ^ ": " ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail (label ^ " unexpectedly succeeded")

let test_typing_failure_correlation () =
  expect_correlation "typing request identity" "typing-request" (function
    | Protocol.Request_id_mismatch _ -> true
    | _ -> false);
  expect_correlation "typing context" "typing-context" (function
    | Protocol.Context_fingerprint_mismatch _ -> true
    | _ -> false);
  expect_correlation "typing AST" "typing-ast" (function
    | Protocol.Ast_digest_mismatch _ -> true
    | _ -> false)

let test_transport_request_limit () =
  let limits =
    Hamlet_subtractor_resolver_transport.
      { default_limits with request_bytes = 8 }
  in
  match run_peer "malformed" ~limits () with
  | Error (Hamlet_subtractor_resolver_transport.Request_too_large _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected request limit result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "oversized request succeeded"

let test_transport_response_limit () =
  let limits =
    Hamlet_subtractor_resolver_transport.
      { default_limits with response_bytes = 64 }
  in
  match run_peer "oversized-response" ~limits () with
  | Error (Hamlet_subtractor_resolver_transport.Response_too_large _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected response limit result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "oversized response succeeded"

let test_transport_stderr_limit () =
  let limits =
    Hamlet_subtractor_resolver_transport.
      { default_limits with stderr_bytes = 64 }
  in
  match run_peer "oversized-stderr" ~limits () with
  | Error (Hamlet_subtractor_resolver_transport.Stderr_too_large _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected stderr limit result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "oversized stderr succeeded"

let test_transport_unexpected_stderr () =
  match run_peer "unexpected-stderr" () with
  | Error (Hamlet_subtractor_resolver_transport.Unexpected_stderr _) -> ()
  | Error error ->
      Alcotest.fail
        ("unexpected stderr result: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "resolver stderr was silently accepted"

let test_transport_input_closed () =
  let source_file = String.make (1024 * 1024) 'x' in
  let request = fake_request ~source_file () in
  let previous =
    Sys.signal Sys.sigpipe (Sys.Signal_handle (fun _ -> assert false))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous)
    (fun () ->
      begin match run_peer "close-input" ~request () with
      | Error Hamlet_subtractor_resolver_transport.Input_closed -> ()
      | Error error ->
          Alcotest.fail
            ("unexpected closed input result: "
            ^ Hamlet_subtractor_resolver_transport.message error)
      | Ok _ -> Alcotest.fail "closed request pipe succeeded"
      end;
      let restored = Sys.signal Sys.sigpipe Sys.Signal_ignore in
      Sys.set_signal Sys.sigpipe restored;
      match restored with
      | Sys.Signal_handle _ -> ()
      | Sys.Signal_default | Sys.Signal_ignore ->
          Alcotest.fail "resolver transport did not restore SIGPIPE handling")

let synthetic_unit fingerprint =
  "Hamlet_subtractor_probe_" ^ String.sub fingerprint 0 16

let request_for_structure
    ?claimed_fingerprint
    ?unit_name
    ~source_file
    structure
    descriptor =
  let context =
    Hamlet_subtractor_compiler_compat.request_context ~source_file structure
  in
  let fingerprint = context.context_fingerprint in
  Protocol.request ~request_id:"semantic-validation" ~source_file
    ~tool_name:"ocamlopt" ~probe_ast:descriptor
    ~probe_unit:
      (Protocol.Synthetic_unit
         (Option.value unit_name ~default:(synthetic_unit fingerprint)))
    ~tool_context:context.tool_context
    ~context_fingerprint:(Option.value claimed_fingerprint ~default:fingerprint)
    ~include_dirs:context.include_dirs
    ~hidden_include_dirs:context.hidden_include_dirs
    ~visible_paths:context.visible_paths ~hidden_paths:context.hidden_paths
    ~opens:context.opens ~package_mode:context.package_mode
    ~compiler_flags:context.compiler_flags ~expected_markers:[]
  |> get_ok "semantic validation request"

let expect_process_failure label fragment = function
  | Error (Hamlet_subtractor_resolver_transport.Process_failed (_, stderr)) ->
      Alcotest.(check bool) label true (contains stderr fragment)
  | Error error ->
      Alcotest.fail
        ("unexpected resolver failure: "
        ^ Hamlet_subtractor_resolver_transport.message error)
  | Ok _ -> Alcotest.fail "invalid resolver request succeeded"

let test_resolver_recomputes_context_fingerprint () =
  let source_file = "semantic_validation.ml" in
  let structure = parse ~source_file "let value = 1" in
  match
    Hamlet_subtractor_resolver_client.with_serialized_probe ~source_file
      structure (fun descriptor ->
        request_for_structure ~claimed_fingerprint:"tampered" ~source_file
          structure descriptor
        |> Hamlet_subtractor_resolver_transport.run)
  with
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  | Ok result ->
      expect_process_failure "fingerprint mismatch is named"
        "context_fingerprint mismatch" result

let test_resolver_derives_synthetic_unit () =
  let source_file = "semantic_validation.ml" in
  let structure = parse ~source_file "let value = 1" in
  match
    Hamlet_subtractor_resolver_client.with_serialized_probe ~source_file
      structure (fun descriptor ->
        request_for_structure ~unit_name:"Hamlet_subtractor_probe_tampered"
          ~source_file structure descriptor
        |> Hamlet_subtractor_resolver_transport.run)
  with
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  | Ok result ->
      expect_process_failure "probe unit mismatch is named"
        "probe_unit mismatch" result

let test_resolver_rejects_oversized_ast () =
  let path, channel =
    Filename.open_temp_file "hamlet-subtractor-large-" ".ast"
  in
  let size = (64 * 1024 * 1024) + 1 in
  Fun.protect ~finally:(fun () -> Sys.remove path) @@ fun () ->
  Unix.LargeFile.ftruncate
    (Unix.descr_of_out_channel channel)
    (Int64.of_int size);
  close_out channel;
  let descriptor =
    Protocol.
      {
        path;
        input_name = "fault.ml";
        magic = Compiler_config.ast_impl_magic_number;
        digest = "not-read-before-size-check";
        byte_length = size;
      }
  in
  fake_request ~descriptor ()
  |> Hamlet_subtractor_resolver_transport.run
  |> expect_process_failure "AST limit is named" "exceeds the resolver limit"

let test_resolver_rejects_dependency_scan () =
  fake_request ~tool_name:"ocamldep" ()
  |> Hamlet_subtractor_resolver_transport.run
  |> expect_process_failure "dependency scan is named"
       "dependency scans cannot invoke"

let test_resolver_rejects_fast_pipeline () =
  fake_request ~tool_name:"dune" ()
  |> Hamlet_subtractor_resolver_transport.run
  |> expect_process_failure "fast caller is named" "unsupported resolver caller"

let parity_source =
  {|
let source = Hamlet.Combinators.fail (`Remain 1)

let handled =
  Hamlet.Combinators.catch source ~handler:(function
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:parity"]))
|}

let exact_prelude =
  {|
module Local_io = struct
  module Errors = struct
    type read_error = [ `Read of int ] [@@hamlet.subtractor.error_leaf.v1]
    type write_error = [ `Write of string ] [@@hamlet.subtractor.error_leaf.v1]
    type error = [ read_error | write_error ] [@@hamlet.subtractor.error_union.v1]
  end
end

module Logger = struct
  module Tag = struct
    type t = unit
    type r = [ `Logger of t Hamlet.P.t ] [@@hamlet.subtractor.service_tag.v1]
    let summon : (unit, Hamlet.never, [> r]) Hamlet.t = assert false
    let give (_ : r) (_ : t) : 'r Hamlet.Dispatch.t = assert false
  end
end
|}

let final_ast prepared engine =
  Hamlet_subtractor_replace.structure
    ~catalogues:(Hamlet_subtractor_engine.catalogues engine)
    ~outcomes:(Hamlet_subtractor_engine.outcomes engine)
    ~resolved_values:(Hamlet_subtractor_engine.resolved_values engine)
    prepared.Hamlet_subtractor_probe.base_structure
  |> get_ok "final replacement"
  |> Selected_ast.to_ocaml Selected_ast.Type.Structure
  |> Format.asprintf "%a" Compiler_pprintast.structure

let resolve_pair ~source_file source =
  let prepared = parse ~source_file source |> Hamlet_subtractor_probe.prepare in
  let direct =
    Hamlet_subtractor_compiler_compat.resolve_prepared ~tool_name:"ocamlopt"
      ~source_file prepared
    |> get_ok "in-process resolution"
  in
  let process =
    Hamlet_subtractor_resolver_client.resolve_prepared ~tool_name:"ocamlopt"
      ~source_file prepared
    |> function
    | Ok value -> value
    | Error error ->
        Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  in
  (prepared, direct, process)

let check_engine_parity label direct process =
  Alcotest.(check bool)
    (label ^ " outcomes") true
    (Hamlet_subtractor_engine.outcomes direct
    = Hamlet_subtractor_engine.outcomes process);
  Alcotest.(check bool)
    (label ^ " catalogues") true
    (Hamlet_subtractor_engine.catalogues direct
    = Hamlet_subtractor_engine.catalogues process);
  Alcotest.(check bool)
    (label ^ " certificates") true
    (Hamlet_subtractor_engine.resolved_values direct
    = Hamlet_subtractor_engine.resolved_values process)

let test_process_and_in_process_parity () =
  with_hamlet @@ fun () ->
  let source_file = "resolver_parity.ml" in
  let prepared =
    parse ~source_file parity_source |> Hamlet_subtractor_probe.prepare
  in
  Alcotest.(check int) "one marker" 1 (List.length prepared.markers);
  let direct =
    Hamlet_subtractor_compiler_compat.resolve_prepared ~tool_name:"ocamlopt"
      ~source_file prepared
    |> get_ok "in-process resolution"
  in
  let process =
    Hamlet_subtractor_resolver_client.resolve_prepared ~tool_name:"ocamlopt"
      ~source_file prepared
    |> function
    | Ok value -> value
    | Error error ->
        Alcotest.fail (Hamlet_subtractor_resolver_client.message error)
  in
  let direct_values = Hamlet_subtractor_engine.resolved_values direct in
  let process_values = Hamlet_subtractor_engine.resolved_values process in
  begin match (direct_values, process_values) with
  | [ (direct_marker, direct) ], [ (process_marker, process) ] ->
      Alcotest.(check bool)
        "marker parity" true
        (Marker.equal direct_marker process_marker);
      Alcotest.(check bool)
        "residual parity" true
        (Residual.equal direct.residual process.residual);
      Alcotest.(check bool)
        "certificate parity" true
        (Effect_certificate.equal direct.certificate process.certificate)
  | _ -> Alcotest.fail "expected one resolved value from each backend"
  end;
  Alcotest.(check bool)
    "catalogue parity" true
    (Stdlib.compare
       (Hamlet_subtractor_engine.catalogues direct)
       (Hamlet_subtractor_engine.catalogues process)
    = 0);
  Alcotest.(check string)
    "final AST parity"
    (final_ast prepared direct)
    (final_ast prepared process)

let test_process_cases_catalogue_parity () =
  with_test_services @@ fun () ->
  let source =
    {|
open Hamlet_test_services

let source :
    (unit, RemoteCache.Errors.error, Hamlet.never) Hamlet.t =
  assert false

let handled =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #RemoteCache.Errors.rc_miss -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:cases-process"]))
|}
  in
  let prepared, direct, process =
    resolve_pair ~source_file:"process_cases.ml" source
  in
  check_engine_parity "Cases" direct process;
  Alcotest.(check int)
    "one external catalogue" 1
    (List.length (Hamlet_subtractor_engine.catalogues process));
  let rendered = final_ast prepared process in
  Alcotest.(check bool)
    "Cases dispatcher generated" true
    (contains rendered "Cases.dispatch")

let test_process_requirement_parity () =
  with_hamlet @@ fun () ->
  let source =
    exact_prelude
    ^ {|
let source :
    (unit, Local_io.Errors.read_error, Logger.Tag.r) Hamlet.t =
  assert false

let provided =
  Hamlet.Combinators.provide source ~handler:(fun requirement ->
    match requirement with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:process-requirement"]))
|}
  in
  let prepared, direct, process =
    resolve_pair ~source_file:"process_requirement.ml" source
  in
  check_engine_parity "requirement" direct process;
  let rendered = final_ast prepared process in
  Alcotest.(check bool)
    "requirement forwarding generated" true
    (contains rendered "Hamlet.Dispatch.need")

let test_process_refusal_parity () =
  with_hamlet @@ fun () ->
  let source =
    exact_prelude
    ^ {|
let handled source =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:process-refusal"]))
|}
  in
  let _, direct, process =
    resolve_pair ~source_file:"process_refusal.ml" source
  in
  check_engine_parity "refusal" direct process;
  match Hamlet_subtractor_engine.outcomes process with
  | [ (_, Protocol.Refused diagnostic) ] ->
      begin match Diagnostic.code diagnostic with
      | Diagnostic.Polymorphic_parameter | Diagnostic.Higher_order_flow -> ()
      | _ -> Alcotest.fail "process refusal changed diagnostic category"
      end
  | _ -> Alcotest.fail "expected one process refusal"

let test_process_dependent_marker_parity () =
  with_hamlet @@ fun () ->
  let source =
    exact_prelude
    ^ {|
let source = Hamlet.Combinators.fail (`Read 1)

let recovered =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Logger.Tag.summon
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:process-inner"]))

let provided =
  Hamlet.Combinators.provide recovered ~handler:(fun requirement ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:process-outer"]))
|}
  in
  let prepared, direct, process =
    resolve_pair ~source_file:"process_dependent.ml" source
  in
  check_engine_parity "dependent markers" direct process;
  Alcotest.(check int)
    "two process outcomes" 2
    (List.length (Hamlet_subtractor_engine.outcomes process));
  Alcotest.(check string)
    "dependent final AST"
    (final_ast prepared direct)
    (final_ast prepared process)

let test_process_wrapped_for_pack_context () =
  with_test_services @@ fun () ->
  let previous_pack = !Compiler_clflags.for_package in
  let previous_opens = !Compiler_clflags.open_modules in
  Fun.protect
    ~finally:(fun () ->
      Compiler_clflags.for_package := previous_pack;
      Compiler_clflags.open_modules := previous_opens)
    (fun () ->
      Compiler_clflags.for_package := Some "Hamlet_test_bundle";
      Compiler_clflags.open_modules := "Hamlet_test_services" :: previous_opens;
      let source =
        {|
let source :
    (unit, RemoteCache.Errors.error, Hamlet.never) Hamlet.t =
  assert false

let handled =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #RemoteCache.Errors.rc_miss -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:wrapped-process"]))
|}
      in
      let prepared =
        parse ~source_file:"wrapped_process.ml" source
        |> Hamlet_subtractor_probe.prepare
      in
      let context =
        Hamlet_subtractor_compiler_compat.request_context
          ~source_file:"wrapped_process.ml" prepared.probe_structure
      in
      begin match context.package_mode with
      | Protocol.For_pack "Hamlet_test_bundle" -> ()
      | _ -> Alcotest.fail "for-pack context was not captured"
      end;
      Alcotest.(check bool)
        "wrapper open captured" true
        (List.mem "Hamlet_test_services" context.opens);
      let prepared, direct, process =
        resolve_pair ~source_file:"wrapped_process.ml" source
      in
      check_engine_parity "wrapped for-pack" direct process;
      Alcotest.(check string)
        "wrapped final AST"
        (final_ast prepared direct)
        (final_ast prepared process))

(* This is an in-process differential guard only. It does not claim that an
   external PPX observes flags omitted from [ocaml.ppx.context]. *)
let test_in_process_proof_is_invariant_under_nonsemantic_flags () =
  with_hamlet @@ fun () ->
  let source_file = "resolver_flag_parity.ml" in
  let prepared =
    parse ~source_file parity_source |> Hamlet_subtractor_probe.prepare
  in
  let baseline =
    Hamlet_subtractor_compiler_compat.resolve_prepared ~tool_name:"ocamlopt"
      ~source_file prepared
    |> get_ok "baseline flag resolution"
  in
  let baseline_ast = final_ast prepared baseline in
  let flags =
    [
      ("standard include", Compiler_clflags.no_std_include);
      ("real paths", Compiler_clflags.real_paths);
      ("current directory", Compiler_clflags.no_cwd);
      ("location retention", Compiler_clflags.keep_locs);
      ("native compiler mode", Compiler_clflags.native_code);
    ]
  in
  List.iter
    (fun (name, flag) ->
      let previous = !flag in
      let resolved =
        Fun.protect ~finally:(fun () -> flag := previous) @@ fun () ->
        flag := not previous;
        Hamlet_subtractor_compiler_compat.resolve_prepared ~tool_name:"ocamlopt"
          ~source_file prepared
      in
      match resolved with
      | Error _ -> Alcotest.fail (name ^ " changed supported proof acceptance")
      | Ok engine ->
          Alcotest.(check string)
            (name ^ " final AST") baseline_ast
            (final_ast prepared engine))
    flags

let test_source_tree_site_lookup () =
  match Hamlet_subtractor_resolver_transport.find_resolver () with
  | Error error ->
      Alcotest.fail (Hamlet_subtractor_resolver_transport.message error)
  | Ok resolver ->
      Alcotest.(check bool)
        "absolute resolver" false
        (Filename.is_relative resolver);
      Alcotest.(check string)
        "site basename" "hamlet-subtractor-resolver"
        (Filename.basename resolver)

let test_source_tree_candidate_derivation () =
  let candidates =
    Hamlet_subtractor_resolver_transport.source_tree_candidates
      ~executable_name:"/workspace/_build/editor/.ppx/driver/ppx.exe"
  in
  let expected =
    if Sys.win32 then
      "/workspace/_build/editor/subtractor/hamlet-subtractor-resolver.exe"
    else "/workspace/_build/editor/subtractor/hamlet_subtractor_resolver.exe"
  in
  Alcotest.(check bool) "same build context" true (List.mem expected candidates)

let () =
  Alcotest.run "hamlet elaboration resolver"
    [
      ( "binary AST",
        [
          Alcotest.test_case "locations are preserved" `Quick
            test_binary_ast_preserves_locations;
          Alcotest.test_case "normal return removes the file" `Quick
            test_serialized_probe_cleanup_on_success;
          Alcotest.test_case "callback exception removes the file" `Quick
            test_serialized_probe_cleanup_on_callback_exception;
          Alcotest.test_case "child timeout removes the file" `Quick
            test_serialized_probe_cleanup_on_child_timeout;
        ] );
      ( "transport",
        [
          Alcotest.test_case "crash is reported" `Quick test_transport_crash;
          Alcotest.test_case "timeout kills the child" `Quick
            test_transport_timeout;
          Alcotest.test_case "malformed response is rejected" `Quick
            test_transport_malformed_response;
          Alcotest.test_case "version mismatch is rejected" `Quick
            test_transport_version_mismatch;
          Alcotest.test_case "context mismatch is rejected" `Quick
            test_transport_context_mismatch;
          Alcotest.test_case "typing failures are correlated" `Quick
            test_typing_failure_correlation;
          Alcotest.test_case "request limit is enforced" `Quick
            test_transport_request_limit;
          Alcotest.test_case "response limit is enforced" `Quick
            test_transport_response_limit;
          Alcotest.test_case "stderr limit is enforced" `Quick
            test_transport_stderr_limit;
          Alcotest.test_case "successful stderr is rejected" `Quick
            test_transport_unexpected_stderr;
          Alcotest.test_case "closed input is reported" `Quick
            test_transport_input_closed;
          Alcotest.test_case "oversized AST is rejected" `Quick
            test_resolver_rejects_oversized_ast;
          Alcotest.test_case "dependency scans are rejected" `Quick
            test_resolver_rejects_dependency_scan;
          Alcotest.test_case "fast pipeline callers are rejected" `Quick
            test_resolver_rejects_fast_pipeline;
        ] );
      ( "backend",
        [
          Alcotest.test_case "source-tree site lookup" `Quick
            test_source_tree_site_lookup;
          Alcotest.test_case "source-tree candidate derivation" `Quick
            test_source_tree_candidate_derivation;
          Alcotest.test_case "proof and final AST parity" `Quick
            test_process_and_in_process_parity;
          Alcotest.test_case "Cases catalogue process parity" `Quick
            test_process_cases_catalogue_parity;
          Alcotest.test_case "requirement process parity" `Quick
            test_process_requirement_parity;
          Alcotest.test_case "refusal process parity" `Quick
            test_process_refusal_parity;
          Alcotest.test_case "dependent marker process parity" `Quick
            test_process_dependent_marker_parity;
          Alcotest.test_case "wrapped for-pack process context" `Quick
            test_process_wrapped_for_pack_context;
          Alcotest.test_case
            "in-process proof ignores selected nonsemantic flags" `Quick
            test_in_process_proof_is_invariant_under_nonsemantic_flags;
          Alcotest.test_case "child recomputes the context fingerprint" `Quick
            test_resolver_recomputes_context_fingerprint;
          Alcotest.test_case "child derives the synthetic unit" `Quick
            test_resolver_derives_synthetic_unit;
        ] );
    ]
