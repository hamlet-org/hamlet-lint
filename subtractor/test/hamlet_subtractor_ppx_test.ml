module Compiler_pprintast = Pprintast
module Compiler_location = Location
module Compiler_clflags = Clflags
module Compiler_compmisc = Compmisc
module Compiler_env = Env
module Compiler_load_path = Load_path

open Ppxlib
open Hamlet_subtractor_core

let parse ?(source_file = "bundle_test.ml") source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf source_file;
  Parse.implementation lexbuf

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

let with_hamlet f =
  let directory = find_hamlet_cmi_directory () in
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

let marker_attributes structure =
  let attributes = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        List.iter
          (fun attribute ->
            if
              String.equal attribute.attr_name.txt "hamlet.subtractor.marker.v1"
            then attributes := attribute :: !attributes)
          expression.pexp_attributes;
        super#expression expression
    end
  in
  iterator#structure structure;
  !attributes

let marker_expressions structure =
  let expressions = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        if
          List.exists
            (fun attribute ->
              String.equal attribute.attr_name.txt "hamlet.subtractor.marker.v1")
            expression.pexp_attributes
        then expressions := expression :: !expressions;
        super#expression expression
    end
  in
  iterator#structure structure;
  !expressions

let auto_pattern_locations structure =
  let locations = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! pattern pattern =
        begin match pattern.ppat_desc with
        | Ppat_extension ({ txt = "hamlet.propagate_e.auto"; _ }, _) ->
            locations := pattern.ppat_loc :: !locations
        | _ -> ()
        end;
        super#pattern pattern
    end
  in
  iterator#structure structure;
  !locations

let probe_transform structure =
  Hamlet_subtractor_ppx.activate_probe_phase ();
  Fun.protect ~finally:Hamlet_subtractor_ppx.reset_phase (fun () ->
      Ppx_hamlet.impl structure)

let test_bundle_phase_overrides_standalone_default () =
  let source =
    parse
      "let handle value =\n\
       match value with\n\
       | `Handled -> assert false\n\
       | [%hamlet.propagate_e.auto] -> ."
  in
  Ppx_hamlet.subtractor_phase := Ppx_hamlet.Normal;
  let standalone_refused =
    try
      Ppx_hamlet.impl source |> ignore;
      false
    with Location.Error _ -> true
  in
  Alcotest.(check bool) "standalone refuses auto" true standalone_refused;
  let probe = probe_transform source in
  Alcotest.(check int)
    "bundle produces one marker" 1
    (List.length (marker_attributes probe))

let test_probe_marker_keeps_original_span () =
  let source =
    parse
      "let handle value =\n\
       match value with\n\
       | `Handled -> assert false\n\
       | [%hamlet.propagate_e.auto] -> ."
  in
  let original_loc = auto_pattern_locations source |> List.hd in
  let marker = probe_transform source |> marker_expressions |> List.hd in
  Alcotest.(check int)
    "marker start" original_loc.loc_start.pos_cnum
    marker.pexp_loc.loc_start.pos_cnum;
  Alcotest.(check int)
    "marker end" original_loc.loc_end.pos_cnum marker.pexp_loc.loc_end.pos_cnum;
  Alcotest.(check bool) "marker span is source" false marker.pexp_loc.loc_ghost

let position cnum =
  { Lexing.pos_fname = "multi.ml"; pos_lnum = 1; pos_bol = 0; pos_cnum = cnum }

let location start_offset end_offset =
  {
    Location.loc_start = position start_offset;
    loc_end = position end_offset;
    loc_ghost = false;
  }

let probe_marker ?(kind = Hamlet_subtractor_probe.Error_propagation) id loc =
  Hamlet_subtractor_probe.{ id; original_id = id; kind; loc }

let core_marker ?(kind = Kind.Error) id loc =
  let id = Marker.id_of_string id |> Result.get_ok in
  let span =
    Source_span.make ~file:"multi.ml"
      ~start_offset:loc.Location.loc_start.pos_cnum
      ~end_offset:loc.loc_end.pos_cnum ~start_line:1
      ~start_column:loc.loc_start.pos_cnum ~end_line:1
      ~end_column:loc.loc_end.pos_cnum
    |> Result.get_ok
  in
  Marker.make ~id ~kind ~span

let test_diagnostics_are_actionable_and_marker_local () =
  let first_loc = location 10 12 in
  let second_loc = location 30 32 in
  let first = probe_marker "e:first" first_loc in
  let second = probe_marker "e:second" second_loc in
  let prepared =
    Hamlet_subtractor_probe.
      {
        base_structure = [];
        probe_structure = [];
        structure = [];
        markers = [ first; second ];
        owners = [];
        refusals = [];
      }
  in
  let refusal =
    Hamlet_subtractor_compiler_evidence.
      {
        marker = core_marker "e:second" second_loc;
        reason = Hamlet_subtractor_compiler_evidence.Higher_order_flow;
      }
  in
  let refusal = Hamlet_subtractor_compiler_compat.Evidence_failed refusal in
  let actual_loc =
    Hamlet_subtractor_ppx.compiler_refusal_loc prepared refusal
  in
  Alcotest.(check int) "second marker location" 30 actual_loc.loc_start.pos_cnum;
  let typing_message =
    Hamlet_subtractor_ppx.compiler_refusal_message prepared
      (Hamlet_subtractor_compiler_compat.Typing_failed
         { message = "private compiler detail"; location = None })
  in
  Alcotest.(check bool)
    "typing fallback" true
    (contains typing_message "%hamlet.te");
  Alcotest.(check bool)
    "no compiler detail" false
    (contains typing_message "private compiler");
  Alcotest.(check bool) "no patch artifact" false (contains typing_message "+");
  let evidence_message =
    Hamlet_subtractor_ppx.compiler_refusal_message prepared
      (Hamlet_subtractor_compiler_compat.Evidence_failed
         {
           marker = core_marker "e:second" second_loc;
           reason = Hamlet_subtractor_compiler_evidence.Unsupported_pattern;
         })
  in
  Alcotest.(check bool)
    "specific evidence reason" true
    (contains evidence_message "handler pattern");
  Alcotest.(check bool)
    "error annotation" true
    (contains evidence_message "%hamlet.te");
  Alcotest.(check bool)
    "error propagation" true
    (contains evidence_message "%hamlet.propagate_e");
  let requirement =
    probe_marker ~kind:Hamlet_subtractor_probe.Requirement_propagation "s:req"
      second_loc
  in
  let requirement_prepared = { prepared with markers = [ requirement ] } in
  let requirement_message =
    Hamlet_subtractor_ppx.compiler_refusal_message requirement_prepared
      (Hamlet_subtractor_compiler_compat.Typing_failed
         { message = "hidden"; location = None })
  in
  Alcotest.(check bool)
    "requirement annotation" true
    (contains requirement_message "%hamlet.ts");
  Alcotest.(check bool)
    "requirement propagation" true
    (contains requirement_message "%hamlet.propagate_s");
  let requirement_diagnostic =
    Diagnostic.make
      ~marker:(core_marker ~kind:Kind.Requirement "s:req" second_loc)
      ~code:Diagnostic.Open_row
  in
  let replacement_message =
    Hamlet_subtractor_ppx.replacement_message requirement_prepared
      (Hamlet_subtractor_replace.Refused requirement_diagnostic)
  in
  Alcotest.(check bool)
    "replacement keeps reason" true
    (contains replacement_message "finite closed row");
  Alcotest.(check bool)
    "replacement requirement annotation" true
    (contains replacement_message "%hamlet.ts");
  Alcotest.(check bool)
    "replacement requirement propagation" true
    (contains replacement_message "%hamlet.propagate_s")

let test_fast_pipeline_diagnostic () =
  let loc = location 10 12 in
  let marker = probe_marker "e:fast" loc in
  let message = Hamlet_subtractor_ppx.fast_pipeline_message marker in
  Alcotest.(check bool)
    "requires staged_pps" true
    (contains message "staged_pps hamlet-subtractor.ppx");
  Alcotest.(check bool)
    "rejects pps" true
    (contains message "not (pps hamlet-subtractor.ppx)");
  Alcotest.(check bool) "explicit fallback" true (contains message "%hamlet.te")

let test_public_ppx_uses_process_resolver () =
  with_hamlet @@ fun () ->
  let source_file = "public_ppx_process.ml" in
  let source =
    parse ~source_file
      "let source = Hamlet.Combinators.fail (`Remain 1)\n\n\
       let handled =\n\
       Hamlet.Combinators.catch source ~handler:(function\n\
       | [%hamlet.propagate_e.auto] -> .)"
  in
  let probe =
    Fun.protect ~finally:Hamlet_subtractor_ppx.reset_phase @@ fun () ->
    Hamlet_subtractor_ppx.activate_probe_phase ();
    Ppx_hamlet.impl source
  in
  let context =
    Expansion_context.Base.top_level ~tool_name:"ocamlopt"
      ~file_path:source_file ~input_name:source_file
  in
  let resolved = Hamlet_subtractor_ppx.resolve ~context probe in
  Alcotest.(check int)
    "marker attributes removed" 0
    (List.length (marker_attributes resolved));
  let rendered =
    Selected_ast.to_ocaml Selected_ast.Type.Structure resolved
    |> Format.asprintf "%a" Compiler_pprintast.structure
  in
  Alcotest.(check bool)
    "residual uses fail" true
    (contains rendered "Hamlet.Combinators.fail")

let test_remote_typing_failure_preserves_location () =
  with_hamlet @@ fun () ->
  let source_file = "remote_typing_failure.ml" in
  let source =
    parse ~source_file
      "let broken = definitely_unbound\n\n\
       let source = Hamlet.Combinators.fail (`Remain 1)\n\n\
       let handled =\n\
       Hamlet.Combinators.catch source ~handler:(function\n\
       | [%hamlet.propagate_e.auto] -> .)"
  in
  let probe =
    Fun.protect ~finally:Hamlet_subtractor_ppx.reset_phase @@ fun () ->
    Hamlet_subtractor_ppx.activate_probe_phase ();
    Ppx_hamlet.impl source
  in
  let context =
    Expansion_context.Base.top_level ~tool_name:"ocamlopt"
      ~file_path:source_file ~input_name:source_file
  in
  try
    Hamlet_subtractor_ppx.resolve ~context probe |> ignore;
    Alcotest.fail "ill-typed probe unexpectedly resolved"
  with exn -> (
    match Compiler_location.error_of_exn exn with
    | Some (`Ok report) ->
        let location = report.main.loc in
        Alcotest.(check string)
          "original filename" source_file location.loc_start.pos_fname;
        Alcotest.(check int)
          "error precedes marker" 1 location.loc_start.pos_lnum
    | Some `Already_displayed | None ->
        Alcotest.fail "resolver error lost its compiler location")

let test_wrong_channel_diagnostic () =
  let prepared =
    parse
      "let value = Combinators.catch source ~handler:(function\n\
       | [%hamlet.propagate_s.auto] -> .)"
    |> probe_transform
    |> Hamlet_subtractor_probe.prepare
  in
  match prepared.refusals with
  | [ refusal ] ->
      let message = Hamlet_subtractor_ppx.probe_refusal_message refusal in
      Alcotest.(check bool)
        "kind mismatch" true
        (contains message "kind mismatch");
      Alcotest.(check bool)
        "required error spelling" true
        (contains message "propagate_e.auto");
      Alcotest.(check bool)
        "no requirement fallback" false
        (contains message "%hamlet.ts");
      Alcotest.(check int)
        "marker-local diagnostic" refusal.marker.loc.loc_start.pos_cnum
        refusal.loc.loc_start.pos_cnum
  | _ -> Alcotest.fail "expected one wrong-channel refusal"

let test_unknown_tool_is_refused_at_marker () =
  let source =
    parse
      "let handle value =\n\
       match value with\n\
       | `Handled -> assert false\n\
       | [%hamlet.propagate_e.auto] -> ."
  in
  let original_loc = auto_pattern_locations source |> List.hd in
  let probe = probe_transform source in
  let context =
    Expansion_context.Base.top_level ~tool_name:"unverified-ppx-host"
      ~file_path:"bundle_test.ml" ~input_name:"bundle_test.ml"
  in
  let error =
    try
      Hamlet_subtractor_ppx.resolve ~context probe |> ignore;
      Alcotest.fail "an unknown PPX tool context was accepted"
    with Location.Error error -> error
  in
  let name, _ = Location.Error.to_extension error in
  Alcotest.(check int)
    "diagnostic start" original_loc.loc_start.pos_cnum
    name.loc.loc_start.pos_cnum;
  Alcotest.(check int)
    "diagnostic end" original_loc.loc_end.pos_cnum name.loc.loc_end.pos_cnum;
  let message = Location.Error.message error in
  Alcotest.(check bool)
    "names unknown tool" true
    (contains message "unverified-ppx-host");
  Alcotest.(check bool) "error annotation" true (contains message "%hamlet.te");
  Alcotest.(check bool)
    "error propagation" true
    (contains message "%hamlet.propagate_e")

module Generic_definition = Hamlet_subtractor_ppx.Generic_definition

let render_structure structure =
  Selected_ast.to_ocaml Selected_ast.Type.Structure structure
  |> Format.asprintf "%a" Compiler_pprintast.structure

let generic_transform source =
  source |> parse |> probe_transform |> Generic_definition.rewrite_exn

let check_rendered label fragment rendered =
  Alcotest.(check bool) label true (contains rendered fragment)

let test_generic_one_error_slot () =
  let transformed =
    generic_transform
      "let[@hamlet.generic] recover source =\n\
       Hamlet.Combinators.catch source ~handler:(function\n\
       | `Missing -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
  in
  let rendered = render_structure transformed in
  check_rendered "evidence parameter"
    "recover source _hamlet_subtractor_recover_slot_0" rendered;
  check_rendered "dispatch" "Hamlet_subtractor.Evidence.dispatch" rendered;
  check_rendered "forward callback" "Hamlet.Combinators.fail" rendered;
  check_rendered "companion" "Hamlet_subtractor_contract__recover" rendered;
  Alcotest.(check bool)
    "source annotation removed" false
    (contains rendered "hamlet.generic");
  Alcotest.(check bool)
    "auto marker removed" false
    (contains rendered "hamlet.subtractor.marker.v1");
  Alcotest.(check int)
    "generic marker does not reach the ordinary probe" 0
    (List.length (Hamlet_subtractor_probe.prepare transformed).markers)

let test_generic_requirement_pipeline () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] provide_logger logger source =\n\
       source\n\
       |> Hamlet.Combinators.provide ~handler:(function\n\
       | #Logger.Tag.r as witness -> Logger.Tag.give witness logger\n\
       | [%hamlet.propagate_s.auto] -> .)"
    |> render_structure
  in
  check_rendered "pipeline retained" "|>" rendered;
  check_rendered "need callback" "Hamlet.Dispatch.need" rendered;
  List.iter
    (fun attribute -> check_rendered attribute attribute rendered)
    [
      Generic_definition.owner_attribute;
      Generic_definition.callee_attribute;
      Generic_definition.upstream_attribute;
      Generic_definition.handler_attribute;
      Generic_definition.slot_attribute;
    ]

let test_generic_two_alternating_slots () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] handle logger source =\n\
       Hamlet.Combinators.provide\n\
       (Hamlet.Combinators.catch source ~handler:(function\n\
       | `Missing -> Hamlet.Combinators.fail `Recovery\n\
       | [%hamlet.propagate_e.auto] -> .))\n\
       ~handler:(function\n\
       | #Logger.Tag.r as witness -> Logger.Tag.give witness logger\n\
       | [%hamlet.propagate_s.auto] -> .)"
    |> render_structure
  in
  check_rendered "tuple evidence"
    "(_hamlet_subtractor_handle_slot_0, _hamlet_subtractor_handle_slot_1)"
    rendered;
  check_rendered "recovery preserved" "`Recovery" rendered

let test_generic_pipeline_two_error_slots () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] handle source =\n\
       source\n\
       |> Hamlet.Combinators.catch ~handler:(function\n\
       | `First -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)\n\
       |> Hamlet.Combinators.catch ~handler:(function\n\
       | `Second -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
    |> render_structure
  in
  check_rendered "first slot" "handle_slot_0" rendered;
  check_rendered "second slot" "handle_slot_1" rendered

let test_generic_guard_forwards_when_false () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] guarded enabled source =\n\
       Hamlet.Combinators.catch source ~handler:(function\n\
       | `Missing when enabled -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
    |> render_structure
  in
  check_rendered "guard retained" "when enabled" rendered;
  check_rendered "guard fallback" "_hamlet_subtractor_guarded_value" rendered;
  check_rendered "guard metadata" "guarded" rendered

let test_generic_fun_match_handler () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] recover source =\n\
       Hamlet.Combinators.catch source ~handler:(fun error ->\n\
       match error with\n\
       | `Missing -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
    |> render_structure
  in
  check_rendered "match handler dispatch" "Evidence.dispatch" rendered;
  check_rendered "match scrutinee" "error" rendered;
  Alcotest.(check bool)
    "marker removed" false
    (contains rendered "hamlet.subtractor.marker.v1")

let test_generic_nested_helper_call () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] outer config source =\n\
       inner config source [%hamlet.forward.auto]"
    |> render_structure
  in
  check_rendered "temporary evidence parameter" "outer config source _" rendered;
  check_rendered "nested call linkage" Generic_definition.nested_call_attribute
    rendered;
  check_rendered "nested callee linkage"
    Generic_definition.nested_callee_attribute rendered;
  check_rendered "nested source linkage"
    Generic_definition.nested_source_attribute rendered;
  check_rendered "nested placeholder linkage"
    Generic_definition.nested_placeholder_attribute rendered;
  Alcotest.(check bool)
    "nested placeholder consumed" false
    (contains rendered "hamlet.forward.auto")

let test_generic_nested_helper_then_local_marker () =
  let rendered =
    generic_transform
      "let[@hamlet.generic] outer config source =\n\
       Hamlet.Combinators.catch\n\
       (inner config source [%hamlet.forward.auto])\n\
       ~handler:(function\n\
       | `Missing -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
    |> render_structure
  in
  check_rendered "nested source feeds local marker"
    Generic_definition.nested_call_attribute rendered;
  check_rendered "local slot remains" "outer_slot_0" rendered;
  check_rendered "local dispatch remains" "Evidence.dispatch" rendered

let test_generic_nested_composition_finalization () =
  let module Exact_contract = Hamlet_subtractor_core.Generic_contract in
  let get_ok label = function
    | Ok value -> value
    | Error _ -> Alcotest.fail ("cannot construct " ^ label)
  in
  let make_slot ordinal inner_id =
    let id =
      Exact_contract.slot_id inner_id |> get_ok "composed slot identity"
    in
    Exact_contract.slot ~id ~ordinal ~kind:Kind.Error
      ~input:(Exact_contract.input Kind.Error)
      ~claimed:[] ~handled:[] ~explicitly_forwarded:[]
      ~recovery:(Exact_contract.clear Kind.Error)
    |> get_ok "composed slot"
  in
  let transformed =
    generic_transform
      "let[@hamlet.generic] outer config source =\n\
       inner config source [%hamlet.forward.auto]"
  in
  let nested_id =
    let values = ref [] in
    let iterator =
      object
        inherit Ast_traverse.iter as super

        method! expression expression =
          expression.pexp_attributes
          |> List.iter (fun attribute ->
              if
                String.equal attribute.attr_name.txt
                  Generic_definition.nested_call_attribute
              then
                match attribute.attr_payload with
                | PStr
                    [
                      {
                        pstr_desc =
                          Pstr_eval
                            ( {
                                pexp_desc =
                                  Pexp_constant (Pconst_string (value, _, _));
                                _;
                              },
                              _ );
                        _;
                      };
                    ] ->
                    values := value :: !values
                | _ -> ());
          super#expression expression
      end
    in
    iterator#structure transformed;
    match !values with
    | [ id ] -> id
    | _ -> Alcotest.fail "expected one nested call identity"
  in
  let slots =
    [
      make_slot 0 (nested_id ^ "/inner-error");
      make_slot 1 (nested_id ^ "/inner-requirement");
    ]
  in
  let contract =
    Exact_contract.create ~helper_fingerprint:"outer-test"
      ~definition_context:"outer-test-context" ~effect_parameter:1 ~slots
      ~output:Exact_contract.input_certificate
    |> get_ok "composed contract"
  in
  let payload =
    Hamlet_subtractor_core.Generic_resolution.encode_definition contract
    |> get_ok "definition attachment"
  in
  let attachment =
    Hamlet_subtractor_core.Protocol.generic_attachment ~id:"definition:outer"
      ~kind:Hamlet_subtractor_core.Protocol.Definition ~payload
    |> get_ok "protocol attachment"
  in
  let rendered =
    Generic_definition.finalize_composition ~attachments:[ attachment ]
      transformed
    |> get_ok "composition finalization"
    |> render_structure
  in
  check_rendered "flattened outer evidence tuple"
    "(_hamlet_subtractor_outer_slot_0, _hamlet_subtractor_outer_slot_1)"
    rendered;
  check_rendered "nested projection uses first slot"
    "_hamlet_subtractor_outer_slot_0" rendered;
  check_rendered "nested projection uses second slot"
    "_hamlet_subtractor_outer_slot_1" rendered;
  Alcotest.(check bool)
    "temporary bottom removed" false
    (contains rendered "assert false")

let expect_generic_refusal label source expected =
  let transformed = source |> parse |> probe_transform in
  match Generic_definition.rewrite transformed with
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
  | Error refusal -> Alcotest.(check bool) label true (expected refusal.reason)

let test_generic_refusals () =
  let invalid_payload =
    let structure = parse "let[@hamlet.generic] helper source = source" in
    let mapper =
      object
        inherit Ast_traverse.map as super

        method! attribute attribute =
          if String.equal attribute.attr_name.txt "hamlet.generic" then
            {
              attribute with
              attr_payload =
                PStr
                  [
                    Ast_builder.Default.pstr_eval ~loc:attribute.attr_loc
                      (Ast_builder.Default.eint ~loc:attribute.attr_loc 1)
                      [];
                  ];
            }
          else super#attribute attribute
      end
    in
    mapper#structure structure
  in
  begin match Generic_definition.rewrite invalid_payload with
  | Error { reason = Generic_definition.Invalid_annotation_payload; _ } -> ()
  | Error _ | Ok _ -> Alcotest.fail "invalid annotation payload was accepted"
  end;
  expect_generic_refusal "recursion"
    "let[@hamlet.generic] rec helper source =\n\
     Hamlet.Combinators.catch source ~handler:(function\n\
     | [%hamlet.propagate_e.auto] -> .)" (function
    | Generic_definition.Recursive_binding -> true
    | _ -> false);
  expect_generic_refusal "non-function" "let[@hamlet.generic] helper = 1"
    (function
    | Generic_definition.Not_a_function -> true
    | _ -> false);
  expect_generic_refusal "no marker"
    "let[@hamlet.generic] helper source = source" (function
    | Generic_definition.No_automatic_markers -> true
    | _ -> false);
  expect_generic_refusal "source used twice"
    "let[@hamlet.generic] helper source =\n\
     Hamlet.Combinators.catch\n\
     (Hamlet.Combinators.both source source)\n\
     ~handler:(function | [%hamlet.propagate_e.auto] -> .)" (function
    | Generic_definition.Source_not_linear 2 -> true
    | _ -> false);
  expect_generic_refusal "opaque source flow"
    "let[@hamlet.generic] helper source =\n\
     Hamlet.Combinators.catch (opaque source)\n\
     ~handler:(function | [%hamlet.propagate_e.auto] -> .)" (function
    | Generic_definition.Unsupported_source_flow -> true
    | _ -> false);
  expect_generic_refusal "multiple symbolic inputs"
    "let[@hamlet.generic] helper left source =\n\
     Hamlet.Combinators.catch\n\
     (Hamlet.Combinators.both left source)\n\
     ~handler:(function | [%hamlet.propagate_e.auto] -> .)" (function
    | Generic_definition.Multiple_symbolic_inputs [ "left" ] -> true
    | _ -> false);
  expect_generic_refusal "marker owner"
    "let[@hamlet.generic] helper source =\n\
     match source with | [%hamlet.propagate_e.auto] -> ." (function
    | Generic_definition.Marker_without_supported_owner -> true
    | _ -> false);
  expect_generic_refusal "nested pipeline"
    "let[@hamlet.generic] helper source =\n\
     source |> inner [%hamlet.forward.auto]" (function
    | Generic_definition.Invalid_nested_call _ -> true
    | _ -> false)

let test_generic_linkage_stripping () =
  let structure =
    generic_transform
      "let[@hamlet.generic] recover source =\n\
       Hamlet.Combinators.catch source ~handler:(function\n\
       | `Missing -> Hamlet.Combinators.success ()\n\
       | [%hamlet.propagate_e.auto] -> .)"
  in
  let rendered =
    Generic_definition.strip_linkage_attributes structure |> render_structure
  in
  List.iter
    (fun attribute ->
      Alcotest.(check bool) attribute false (contains rendered attribute))
    [
      Generic_definition.helper_attribute;
      Generic_definition.owner_attribute;
      Generic_definition.callee_attribute;
      Generic_definition.upstream_attribute;
      Generic_definition.handler_attribute;
      Generic_definition.slot_attribute;
      Generic_definition.nested_call_attribute;
      Generic_definition.nested_callee_attribute;
      Generic_definition.nested_source_attribute;
      Generic_definition.nested_placeholder_attribute;
    ];
  check_rendered "contract remains"
    Hamlet_subtractor_ppx.Generic_contract.attribute_name rendered

let () =
  Alcotest.run "hamlet elaboration PPX bundle"
    [
      ( "driver",
        [
          Alcotest.test_case "bundle phase overrides standalone" `Quick
            test_bundle_phase_overrides_standalone_default;
          Alcotest.test_case "probe marker keeps source span" `Quick
            test_probe_marker_keeps_original_span;
          Alcotest.test_case "diagnostics are marker-local" `Quick
            test_diagnostics_are_actionable_and_marker_local;
          Alcotest.test_case "fast pipeline is rejected" `Quick
            test_fast_pipeline_diagnostic;
          Alcotest.test_case "public PPX uses the process resolver" `Quick
            test_public_ppx_uses_process_resolver;
          Alcotest.test_case "remote typing location is preserved" `Quick
            test_remote_typing_failure_preserves_location;
          Alcotest.test_case "wrong channel is marker-local" `Quick
            test_wrong_channel_diagnostic;
          Alcotest.test_case "unknown PPX tool is rejected" `Quick
            test_unknown_tool_is_refused_at_marker;
        ] );
      ( "generic definitions",
        [
          Alcotest.test_case "one error slot" `Quick test_generic_one_error_slot;
          Alcotest.test_case "requirement pipeline" `Quick
            test_generic_requirement_pipeline;
          Alcotest.test_case "alternating slots" `Quick
            test_generic_two_alternating_slots;
          Alcotest.test_case "two pipeline slots" `Quick
            test_generic_pipeline_two_error_slots;
          Alcotest.test_case "guard fallback" `Quick
            test_generic_guard_forwards_when_false;
          Alcotest.test_case "fun match handler" `Quick
            test_generic_fun_match_handler;
          Alcotest.test_case "nested helper call" `Quick
            test_generic_nested_helper_call;
          Alcotest.test_case "nested helper then local marker" `Quick
            test_generic_nested_helper_then_local_marker;
          Alcotest.test_case "nested composition finalization" `Quick
            test_generic_nested_composition_finalization;
          Alcotest.test_case "stable refusals" `Quick test_generic_refusals;
          Alcotest.test_case "linkage stripping" `Quick
            test_generic_linkage_stripping;
        ] );
    ]
