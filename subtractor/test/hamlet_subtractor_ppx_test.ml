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
    ]
