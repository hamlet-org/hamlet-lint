module Compiler_clflags = Clflags
module Compiler_compmisc = Compmisc
module Compiler_config = Config
module Compiler_env = Env
module Compiler_load_path = Load_path
module Compiler_location = Location
module Compiler_pparse = Pparse
module Compiler_warnings = Warnings

open Ppxlib

let parse ?(source_file = "probe.ml") source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf source_file;
  Parse.implementation lexbuf

let inspect ?(source_file = "probe.ml") structure =
  Hamlet_subtractor_compiler_compat.inspect_probe ~tool_name:"ocamlopt" ~source_file
    structure

let fail_refusal = function
  | Hamlet_subtractor_compiler_compat.Dependency_scan -> "dependency scan"
  | Hamlet_subtractor_compiler_compat.Unsupported_tool tool ->
      "unsupported tool: " ^ tool
  | Hamlet_subtractor_compiler_compat.Typing_failed failure ->
      "typing failed: " ^ failure.message
  | Hamlet_subtractor_compiler_compat.Probe_lookup_failed _ ->
      "probe marker lookup failed"
  | Hamlet_subtractor_compiler_compat.Evidence_failed refusal ->
      Hamlet_subtractor_compiler_evidence.refusal_message refusal
  | Hamlet_subtractor_compiler_compat.Request_context_mismatch
      { field; expected; actual } ->
      Printf.sprintf "context %s mismatch: %s <> %s" field expected actual
  | Hamlet_subtractor_compiler_compat.Probe_ast_failed message ->
      "probe AST failed: " ^ message
  | Hamlet_subtractor_compiler_compat.Protocol_construction_failed _ ->
      "protocol construction failed"
  | Hamlet_subtractor_compiler_compat.Protocol_correlation_failed _ ->
      "protocol correlation failed"

let require_observation = function
  | Ok observation -> observation
  | Error refusal -> Alcotest.fail (fail_refusal refusal)

let test_ocamldep_skips_typing () =
  let structure = parse "let value = definitely_unbound" in
  match
    Hamlet_subtractor_compiler_compat.inspect_probe ~tool_name:"ocamldep"
      ~source_file:"dependency_scan.ml" structure
  with
  | Error Hamlet_subtractor_compiler_compat.Dependency_scan -> ()
  | Error refusal ->
      Alcotest.failf "ocamldep entered the probe: %s" (fail_refusal refusal)
  | Ok _ -> Alcotest.fail "ocamldep unexpectedly typed the probe"

let test_repeated_sessions () =
  let structure = parse "let id value = value" in
  let first = inspect ~source_file:"repeated_probe.ml" structure in
  let second = inspect ~source_file:"repeated_probe.ml" structure in
  let first = require_observation first in
  let second = require_observation second in
  Alcotest.(check int) "first item count" 1 first.structure_items;
  Alcotest.(check int)
    "stable item count" first.structure_items second.structure_items

let test_failure_does_not_poison_next_session () =
  let failed = inspect (parse "let value = definitely_unbound") in
  (match failed with
  | Error (Hamlet_subtractor_compiler_compat.Typing_failed _) -> ()
  | Error refusal -> Alcotest.fail (fail_refusal refusal)
  | Ok _ -> Alcotest.fail "invalid probe unexpectedly typed");
  inspect (parse "let value = 42") |> require_observation
  |> fun (observation : Hamlet_subtractor_compiler_compat.observation) ->
  Alcotest.(check int)
    "successful structure items" 1 observation.structure_items

let find_fixture_cmi_directory () =
  let relative = ".subtractor_dep_fixture.objs/byte/subtractor_dep_fixture.cmi" in
  let executable_directory = Filename.dirname Sys.executable_name in
  let candidates =
    [
      Filename.concat executable_directory relative;
      Filename.concat (Sys.getcwd ()) (Filename.concat "subtractor" relative);
      Filename.concat (Sys.getcwd ())
        (Filename.concat "_build/default/subtractor" relative);
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some cmi -> Filename.dirname cmi
  | None -> Alcotest.fail "cannot locate the sibling CMI fixture"

let test_fresh_store_resolves_sibling_cmi () =
  let cmi_directory = find_fixture_cmi_directory () in
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
      Compiler_clflags.include_dirs := cmi_directory :: previous_include_dirs;
      Compiler_compmisc.init_path ();
      inspect
        (parse
           "let dependency_value = Subtractor_dep_fixture.value\n\
            let consume = function `Only_from_dependency -> ()")
      |> require_observation
      |> fun (observation : Hamlet_subtractor_compiler_compat.observation) ->
      Alcotest.(check int)
        "typed dependency structure" 2 observation.structure_items)

let test_warning_state_is_scoped () =
  let previous = Compiler_warnings.backup () in
  Fun.protect
    ~finally:(fun () ->
      Compiler_warnings.restore previous;
      Compiler_warnings.reset_fatal ())
    (fun () ->
      Compiler_warnings.reset_fatal ();
      Option.iter
        Compiler_location.(prerr_alert none)
        (Compiler_warnings.parse_options false "+11");
      Option.iter
        Compiler_location.(prerr_alert none)
        (Compiler_warnings.parse_options true "+11");
      let warning = Compiler_warnings.Redundant_case in
      Alcotest.(check bool)
        "warning starts active" true
        (Compiler_warnings.is_active warning);
      Alcotest.(check bool)
        "warning starts fatal" true
        (Compiler_warnings.is_error warning);
      inspect (parse "let f = function _ -> 0 | _ -> 1")
      |> require_observation
      |> ignore;
      Alcotest.(check bool)
        "warning remains active" true
        (Compiler_warnings.is_active warning);
      Alcotest.(check bool)
        "warning remains fatal" true
        (Compiler_warnings.is_error warning);
      Compiler_warnings.check_fatal ())

let marker_attribute_name = "hamlet.subtractor.marker.v1"

let has_marker expression =
  List.exists
    (fun attribute ->
      String.equal attribute.attr_name.txt marker_attribute_name)
    expression.pexp_attributes

let attribute_count name structure =
  let count = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! attribute attribute =
        if String.equal attribute.attr_name.txt name then incr count;
        super#attribute attribute
    end
  in
  iterator#structure structure;
  !count

let attribute_string_values name structure =
  let values = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! attribute attribute =
        (if String.equal attribute.attr_name.txt name then
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
        super#attribute attribute
    end
  in
  iterator#structure structure;
  List.rev !values

let force_same_marker_location structure =
  let start =
    {
      Lexing.pos_fname = "same_span.ml";
      pos_lnum = 1;
      pos_bol = 0;
      pos_cnum = 40;
    }
  in
  let loc =
    {
      Location.loc_start = start;
      loc_end = { start with pos_cnum = 45 };
      loc_ghost = false;
    }
  in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        let expression = super#expression expression in
        if has_marker expression then { expression with pexp_loc = loc }
        else expression
    end
  in
  mapper#structure structure

let test_same_span_ids_are_deterministic () =
  let source =
    "let first = (assert false [@hamlet.subtractor.marker.v1 \"e:first\"])\n\
     let second = (assert false [@hamlet.subtractor.marker.v1 \"e:second\"])"
  in
  let structure = parse source |> force_same_marker_location in
  let first = Hamlet_subtractor_probe.prepare structure in
  let second = Hamlet_subtractor_probe.prepare structure in
  let first_ids =
    List.map
      (fun (marker : Hamlet_subtractor_probe.marker) -> marker.id)
      first.markers
  in
  let second_ids =
    List.map
      (fun (marker : Hamlet_subtractor_probe.marker) -> marker.id)
      second.markers
  in
  Alcotest.(check (list string)) "stable IDs" first_ids second_ids;
  match first_ids with
  | [ first_id; second_id ] ->
      Alcotest.(check bool)
        "first ordinal" true
        (String.ends_with ~suffix:":0" first_id);
      Alcotest.(check bool)
        "second ordinal" true
        (String.ends_with ~suffix:":1" second_id);
      Alcotest.(check bool) "IDs differ" false (String.equal first_id second_id);
      Alcotest.(check int) "filename is not exposed" 36 (String.length first_id)
  | _ -> Alcotest.fail "expected two canonical markers"

let test_source_edit_changes_marker_id () =
  let marker context =
    Printf.sprintf
      "let context = %d\n\
       let marker = (assert false [@hamlet.subtractor.marker.v1 \"e:edit\"])"
      context
    |> parse
    |> force_same_marker_location
    |> Hamlet_subtractor_probe.prepare
  in
  let marker_id prepared =
    match prepared.Hamlet_subtractor_probe.markers with
    | [ marker ] -> marker.id
    | _ -> Alcotest.fail "expected one edited-source marker"
  in
  Alcotest.(check bool)
    "whole-AST edits invalidate IDs" false
    (String.equal (marker 1 |> marker_id) (marker 2 |> marker_id))

let inline_row_source =
  "type (+'a, +'e, +'r) t = T\n\
   type a_error = [ `A of int ]\n\
   let fail (error : ([> `B of string ] as 'error)) :\n\
   (unit, 'error, unit) t =\n\
   let _ = error in T\n\
   let catch (eff : ('a, 'error, 'requirements) t)\n\
   ~(handler : 'error -> ('a, 'next_error, 'requirements) t) :\n\
   ('a, 'next_error, 'requirements) t =\n\
   let _ = eff, handler in T\n\
   module Combinators = struct let catch = catch end\n\
   let inline =\n\
   Combinators.catch (fail (`B \"b\")) ~handler:(fun error ->\n\
   match error with\n\
   | #a_error -> T\n\
   | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:inline\"]))"

let variant_labels = function
  | Hamlet_subtractor_probe.Variant row -> Some row.labels
  | _ -> None

let test_inline_upstream_is_isolated () =
  let original = parse ~source_file:"inline_probe.ml" inline_row_source in
  let original_snapshot = Marshal.to_string original [ Marshal.No_sharing ] in
  let prepared = Hamlet_subtractor_probe.prepare original in
  Alcotest.(check int) "one owner" 1 (List.length prepared.owners);
  Alcotest.(check int) "no refusals" 0 (List.length prepared.refusals);
  let after_snapshot = Marshal.to_string original [ Marshal.No_sharing ] in
  Alcotest.(check string)
    "final AST remains untouched" original_snapshot after_snapshot;
  let first =
    inspect ~source_file:"inline_probe.ml" prepared.structure
    |> require_observation
  in
  let second =
    inspect ~source_file:"inline_probe.ml" prepared.structure
    |> require_observation
  in
  let labels observation =
    match observation.Hamlet_subtractor_compiler_compat.links with
    | [ { upstream_type = Constructor (_, arguments); _ } ] -> (
        match Option.bind (List.nth_opt arguments 1) variant_labels with
        | Some labels -> labels
        | None -> Alcotest.fail "upstream error argument is not a variant row")
    | _ -> Alcotest.fail "expected one typed upstream marker link"
  in
  Alcotest.(check (list string))
    "isolated upstream labels" [ "B" ] (labels first);
  Alcotest.(check (list string))
    "first observation survives reset" [ "B" ] (labels first);
  Alcotest.(check (list string)) "repeated observation" [ "B" ] (labels second)

let refusal_reason prepared =
  match prepared.Hamlet_subtractor_probe.refusals with
  | [ refusal ] -> refusal.reason
  | _ -> Alcotest.fail "expected exactly one refusal"

let test_private_owner_refusals () =
  let unsupported =
    parse
      "let value =\n\
       Combinators.catch first second ~handler:(function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:bad-shape\"]))"
    |> Hamlet_subtractor_probe.prepare
  in
  (match refusal_reason unsupported with
  | Unsupported_call_shape -> ()
  | _ -> Alcotest.fail "expected unsupported-call refusal");
  let named =
    parse
      "let handler = function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:named\"])\n\
       let value = Combinators.catch source ~handler"
    |> Hamlet_subtractor_probe.prepare
  in
  (match refusal_reason named with
  | Named_handler -> ()
  | _ -> Alcotest.fail "expected named-handler refusal");
  let ambiguous =
    parse
      "let handler = function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:ambiguous\"])\n\
       let first = Combinators.catch source_one ~handler\n\
       let second = Combinators.catch source_two ~handler"
    |> Hamlet_subtractor_probe.prepare
  in
  match refusal_reason ambiguous with
  | Ambiguous_owner -> ()
  | _ -> Alcotest.fail "expected ambiguous-owner refusal"

let test_wrong_channel_is_refused_before_typing () =
  let prepared =
    parse
      "let value = Combinators.catch source ~handler:(function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"s:wrong-channel\"]))"
    |> Hamlet_subtractor_probe.prepare
  in
  match refusal_reason prepared with
  | Wrong_channel
      { owner = Error_propagation; marker = Requirement_propagation } ->
      ()
  | _ -> Alcotest.fail "expected wrong-channel refusal"

let test_direct_and_pipe_owners () =
  let direct =
    parse
      "let value = Combinators.catch source ~handler:(function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:direct\"]))"
    |> Hamlet_subtractor_probe.prepare
  in
  let pipe =
    parse
      "let value = source |> Hamlet.Combinators.provide ~handler:(function\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \"s:pipe\"]))"
    |> Hamlet_subtractor_probe.prepare
  in
  (match direct.owners with
  | [ { form = Direct; _ } ] -> ()
  | _ -> Alcotest.fail "expected a direct catch owner");
  Alcotest.(check int)
    "direct base owner attr" 1
    (attribute_count "hamlet.subtractor.owner.v1" direct.base_structure);
  (match pipe.owners with
  | [ { form = Pipe; _ } ] -> ()
  | _ -> Alcotest.fail "expected a pipe provide owner");
  Alcotest.(check int)
    "pipe base owner attr" 1
    (attribute_count "hamlet.subtractor.owner.v1" pipe.base_structure)

let test_nested_owners_keep_distinct_ids () =
  let prepared =
    parse
      "let value =\n\
       Combinators.catch source ~handler:(fun error ->\n\
       match error with\n\
       | `Recover ->\n\
       Combinators.catch recovery ~handler:(function\n\
       | _ ->\n\
       (assert false\n\
       [@hamlet.subtractor.marker.v1 \"e:nested-inner\"]))\n\
       | _ ->\n\
       (assert false [@hamlet.subtractor.marker.v1 \"e:nested-outer\"]))"
    |> Hamlet_subtractor_probe.prepare
  in
  Alcotest.(check int) "two nested owners" 2 (List.length prepared.owners);
  Alcotest.(check int)
    "two nested base owner attrs" 2
    (attribute_count "hamlet.subtractor.owner.v1" prepared.base_structure);
  let expected =
    prepared.owners
    |> List.map (fun (owner : Hamlet_subtractor_probe.owner) -> owner.marker.id)
    |> List.sort String.compare
  in
  let actual =
    attribute_string_values "hamlet.subtractor.owner.v1" prepared.base_structure
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "nested owner IDs" expected actual

let test_refused_marker_is_not_a_typed_lookup_failure () =
  let prepared =
    parse "let marker =\n(assert false [@hamlet.subtractor.marker.v1 \"e:no-owner\"])"
    |> Hamlet_subtractor_probe.prepare
  in
  Alcotest.(check int) "one refusal" 1 (List.length prepared.refusals);
  inspect prepared.structure |> require_observation
  |> fun (observation : Hamlet_subtractor_compiler_compat.observation) ->
  Alcotest.(check int)
    "no owned Typedtree links" 0
    (List.length observation.links)

let request_marker () =
  let open Hamlet_subtractor_core in
  let id = Marker.id_of_string "e:request-missing" |> Result.get_ok in
  let span =
    Source_span.make ~file:"request_probe.ml" ~start_offset:0 ~end_offset:1
      ~start_line:1 ~start_column:0 ~end_line:1 ~end_column:1
    |> Result.get_ok
  in
  Marker.make ~id ~kind:Kind.Error ~span

let resolver_request expected_markers =
  let module Protocol = Hamlet_subtractor_core.Protocol in
  let source_name = "request_probe.ml" in
  let structure = parse ~source_file:source_name "let value = ()" in
  let context =
    Hamlet_subtractor_compiler_compat.request_context ~source_file:source_name
      structure
  in
  let path, channel = Filename.open_temp_file "hamlet-request-" ".ast" in
  close_out channel;
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let previous = !Compiler_location.input_name in
  Compiler_location.input_name := source_name;
  Compiler_pparse.write_ast Compiler_pparse.Structure path
    (Selected_ast.to_ocaml Selected_ast.Type.Structure structure);
  Compiler_location.input_name := previous;
  let stats = Unix.stat path in
  let probe_ast =
    Protocol.
      {
        path;
        input_name = source_name;
        magic = Compiler_config.ast_impl_magic_number;
        digest = Digest.file path |> Digest.to_hex;
        byte_length = stats.st_size;
      }
  in
  let probe_unit =
    "Hamlet_subtractor_probe_" ^ String.sub context.context_fingerprint 0 16
  in
  Protocol.request ~request_id:"request-id" ~source_file:source_name
    ~tool_name:"ocamlopt" ~probe_ast
    ~probe_unit:(Protocol.Synthetic_unit probe_unit)
    ~tool_context:context.tool_context
    ~context_fingerprint:context.context_fingerprint
    ~include_dirs:context.include_dirs
    ~hidden_include_dirs:context.hidden_include_dirs
    ~visible_paths:context.visible_paths ~hidden_paths:context.hidden_paths
    ~opens:context.opens ~package_mode:context.package_mode
    ~compiler_flags:context.compiler_flags ~expected_markers
  |> Result.get_ok

let test_resolve_request_success_and_correlation () =
  let module Protocol = Hamlet_subtractor_core.Protocol in
  let request = resolver_request [] in
  let response =
    Hamlet_subtractor_compiler_compat.resolve_request request |> require_observation
  in
  Alcotest.(check int)
    "empty result set" 0
    (List.length (Protocol.results response));
  Alcotest.(check int)
    "empty catalogue set" 0
    (List.length (Protocol.catalogues response));
  let mismatch = resolver_request [ request_marker () ] in
  match Hamlet_subtractor_compiler_compat.resolve_request mismatch with
  | Error
      (Hamlet_subtractor_compiler_compat.Protocol_correlation_failed
         (Protocol.Missing_marker_result _)) ->
      ()
  | Error refusal -> Alcotest.fail (fail_refusal refusal)
  | Ok _ -> Alcotest.fail "mismatched marker set unexpectedly correlated"

let exact_prelude =
  {|
module Local_io = struct
  module Errors = struct
    type read_error = [ `Read of int ] [@@hamlet.subtractor.error_leaf.v1]
    type write_error = [ `Write of string ] [@@hamlet.subtractor.error_leaf.v1]
    type error = [ read_error | write_error ] [@@hamlet.subtractor.error_union.v1]
  end
end

module Remote = struct
  module Errors = struct
    type first = [ `First ] [@@hamlet.subtractor.error_leaf.v1]
    type second = [ `Second of string ] [@@hamlet.subtractor.error_leaf.v1]
    type third = [ `Third ] [@@hamlet.subtractor.error_leaf.v1]
    type error = [ first | second | third ] [@@hamlet.subtractor.error_union.v1]

    module Cases = struct
      type ('a, 'r, 'e) t = {
        e0 : first -> ('a, 'e, 'r) Hamlet.t;
        e1 : second -> ('a, 'e, 'r) Hamlet.t;
        e2 : third -> ('a, 'e, 'r) Hamlet.t;
      }
      [@@hamlet.subtractor.error_cases.v1]
    end
  end
end

module Logger = struct
  module Tag = struct
    type t = unit
    type r = [ `Logger of t Hamlet.P.t ] [@@hamlet.subtractor.service_tag.v1]
    let key : t Hamlet.Service_key.t = Hamlet.Service_key.make ~name:"Logger"
    let tag = (`Logger (Hamlet.P.make : t Hamlet.P.t) : [> r])
    let summon : (unit, Hamlet.never, [> r]) Hamlet.t = assert false
    let give (_ : r) (_ : t) : 'r Hamlet.Dispatch.t = assert false
  end
end

module Clock = struct
  module Tag = struct
    type t = unit
    type r = [ `Clock of t Hamlet.P.t ] [@@hamlet.subtractor.service_tag.v1]
    let key : t Hamlet.Service_key.t = Hamlet.Service_key.make ~name:"Clock"
    let tag = (`Clock (Hamlet.P.make : t Hamlet.P.t) : [> r])
    let summon : (unit, Hamlet.never, [> r]) Hamlet.t = assert false
    let give (_ : r) (_ : t) : 'r Hamlet.Dispatch.t = assert false
    let need (_ : r) : r Hamlet.Dispatch.t = assert false
  end
end
|}

let find_hamlet_cmi_directory () =
  let relative = ".hamlet.objs/byte/hamlet.cmi" in
  let executable_directory = Filename.dirname Sys.executable_name in
  let candidates =
    [
      Filename.concat
        (Filename.dirname executable_directory)
        (Filename.concat "lib" relative);
      Filename.concat (Sys.getcwd ())
        (Filename.concat "_build/default/lib" relative);
      Filename.concat (Sys.getcwd ()) (Filename.concat "lib" relative);
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some cmi -> Filename.dirname cmi
  | None -> Alcotest.fail "cannot locate Hamlet CMI fixture"

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

let resolve_exact
    ?(tool_name = "ocamlopt")
    ?(source_file = "exact_probe.ml")
    source =
  let prepared =
    parse ~source_file (exact_prelude ^ source) |> Hamlet_subtractor_probe.prepare
  in
  with_include_directory (find_hamlet_cmi_directory ()) @@ fun () ->
  match
    Hamlet_subtractor_compiler_compat.resolve_prepared ~tool_name ~source_file
      prepared
  with
  | Ok engine -> engine
  | Error refusal -> Alcotest.fail (fail_refusal refusal)

let only_outcome engine =
  match Hamlet_subtractor_engine.outcomes engine with
  | [ outcome ] -> outcome
  | outcomes ->
      Alcotest.failf "expected one exact outcome, got %d" (List.length outcomes)

let resolved_residual engine =
  match only_outcome engine with
  | _, Hamlet_subtractor_core.Protocol.Resolved residual -> residual
  | _, Refused diagnostic ->
      Alcotest.fail (Hamlet_subtractor_core.Diagnostic.message diagnostic)

let leaf_names leaves =
  List.map
    (fun leaf ->
      Hamlet_subtractor_core.Leaf.identity leaf
      |> Hamlet_subtractor_core.Identity.declaration_name)
    leaves

let leaf_labels leaves =
  leaves
  |> List.concat_map Hamlet_subtractor_core.Leaf.members
  |> List.map Hamlet_subtractor_core.Atom.label
  |> List.sort_uniq String.compare

let test_exact_local_catch () =
  let engine =
    resolve_exact
      {|
let source : (unit, Local_io.Errors.error, Logger.Tag.r) Hamlet.t = assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:catch"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "local union subtracts one direct leaf" [ "write_error" ]
    (Hamlet_subtractor_core.Residual.residual residual |> leaf_names);
  Alcotest.(check int)
    "local union does not fabricate Cases" 0
    (Hamlet_subtractor_engine.catalogues engine |> List.length)

let test_exact_cases_subset () =
  let engine =
    resolve_exact
      {|
type subset = [ Remote.Errors.first | Remote.Errors.second ]

let source = Hamlet.Combinators.fail (`Second "subset" : subset)

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Remote.Errors.first -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:cases-subset"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "proper subset input uses named Cases leaves" [ "first"; "second" ]
    (Hamlet_subtractor_core.Residual.input residual
    |> Hamlet_subtractor_core.Proof.leaves
    |> leaf_names);
  Alcotest.(check (list string))
    "proper subset subtracts one named leaf" [ "second" ]
    (Hamlet_subtractor_core.Residual.residual residual |> leaf_names);
  Alcotest.(check int)
    "complete validated catalogue retained" 1
    (Hamlet_subtractor_engine.catalogues engine |> List.length);
  match
    Hamlet_subtractor_generator.cases ~loc:Location.none
      ~catalogues:(Hamlet_subtractor_engine.catalogues engine)
      residual
  with
  | Ok
      [
        {
          pc_lhs =
            {
              ppat_desc =
                Ppat_alias ({ ppat_desc = Ppat_type { txt = path; _ }; _ }, _);
              _;
            };
          _;
        };
        {
          pc_lhs = { ppat_desc = Ppat_any; _ };
          pc_guard = None;
          pc_rhs = { pexp_desc = Pexp_unreachable; _ };
        };
      ] ->
      Alcotest.(check string)
        "proper subset forwards directly" "Remote.Errors.second"
        (Longident.name path)
  | Ok _ -> Alcotest.fail "proper subset unexpectedly used Cases.dispatch"
  | Error error -> Alcotest.fail (Hamlet_subtractor_generator.error_message error)

let test_transparent_alias_stays_structural () =
  let engine =
    resolve_exact
      {|
module Plain = struct
  type first = [ `Plain_first ]
  type second = [ `Plain_second of int ]
end

type plain_subset = [ Plain.first | Plain.second ]

let source = Hamlet.Combinators.fail (`Plain_second 2 : plain_subset)

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Plain.first -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:plain-subset"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check int)
    "transparent alias has no fabricated catalogue" 0
    (Hamlet_subtractor_engine.catalogues engine |> List.length);
  match
    Hamlet_subtractor_generator.cases ~loc:Location.none ~catalogues:[] residual
  with
  | Ok
      [
        {
          pc_lhs =
            {
              ppat_desc =
                Ppat_alias
                  ({ ppat_desc = Ppat_variant ("Plain_second", Some _); _ }, _);
              _;
            };
          _;
        };
        {
          pc_lhs = { ppat_desc = Ppat_any; _ };
          pc_guard = None;
          pc_rhs = { pexp_desc = Pexp_unreachable; _ };
        };
      ] ->
      ()
  | Ok _ -> Alcotest.fail "transparent alias was not forwarded structurally"
  | Error error -> Alcotest.fail (Hamlet_subtractor_generator.error_message error)

let test_exact_requirement_provide () =
  let engine =
    resolve_exact
      {|
let source : (unit, Local_io.Errors.read_error, Logger.Tag.r) Hamlet.t =
  assert false

let provided =
  Hamlet.Combinators.provide source ~handler:(fun requirement ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:provide"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check int)
    "give discharges the singleton tag" 0
    (Hamlet_subtractor_core.Residual.residual residual |> List.length)

let refused_code engine =
  match only_outcome engine with
  | _, Hamlet_subtractor_core.Protocol.Refused diagnostic ->
      Hamlet_subtractor_core.Diagnostic.code diagnostic
  | _, Resolved _ -> Alcotest.fail "expected exact evidence refusal"

let test_fake_callee_refused () =
  let engine =
    resolve_exact
      {|
module Real_hamlet = Hamlet
module Hamlet = struct
  module Combinators = struct
    let catch = Real_hamlet.Combinators.catch
  end
end

let source :
    (unit, Local_io.Errors.read_error, Logger.Tag.r) Real_hamlet.t =
  assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Real_hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:fake"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Invalid_owner -> ()
  | _ -> Alcotest.fail "local Hamlet lookalike was accepted"

let test_parameter_row_refused () =
  let engine =
    resolve_exact
      {|
let caught source =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:parameter"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Polymorphic_parameter
  | Hamlet_subtractor_core.Diagnostic.Higher_order_flow ->
      ()
  | Hamlet_subtractor_core.Diagnostic.Open_row ->
      Alcotest.fail "parameter refusal was reported only as an open row"
  | Hamlet_subtractor_core.Diagnostic.Unresolved_row ->
      Alcotest.fail "parameter refusal was reported only as unresolved"
  | Hamlet_subtractor_core.Diagnostic.Opaque_origin ->
      Alcotest.fail "parameter refusal was reported only as opaque"
  | _ -> Alcotest.fail "open function parameter row had the wrong refusal"

let test_hidden_alias_refused_as_abstract () =
  let engine =
    resolve_exact
      {|
module Hidden : sig
  type error
  val source : (unit, error, Hamlet.never) Hamlet.t
end = struct
  type error = [ `Hidden ]
  let source : (unit, error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.fail (`Hidden : error)
end

let caught =
  Hamlet.Combinators.catch Hidden.source ~handler:(fun error ->
    match error with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:hidden-alias"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Abstract_alias _ -> ()
  | _ -> Alcotest.fail "hidden alias did not retain its abstract refusal"

let test_private_leaf_aliases_are_refused () =
  let private_error =
    resolve_exact
      {|
module Private_error = struct
  type error = private [ `Private_error ] [@@hamlet.subtractor.error_leaf.v1]
  let source : (unit, error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.return ()
end

let caught =
  Hamlet.Combinators.catch Private_error.source ~handler:(fun error ->
    match error with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:private-error"]))
|}
  in
  (match refused_code private_error with
  | Hamlet_subtractor_core.Diagnostic.Abstract_alias _ -> ()
  | _ -> Alcotest.fail "private error leaf was expanded");
  let private_requirement =
    resolve_exact
      {|
module Private_tag = struct
  type t = unit
  type r = private [ `Private_tag of t Hamlet.P.t ]
    [@@hamlet.subtractor.service_tag.v1]
end

let source : (unit, Hamlet.never, Private_tag.r) Hamlet.t =
  Hamlet.Combinators.return ()

let provided =
  Hamlet.Combinators.provide source ~handler:(fun requirement ->
    match requirement with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:private-requirement"]))
|}
  in
  match refused_code private_requirement with
  | Hamlet_subtractor_core.Diagnostic.Abstract_alias _ -> ()
  | _ -> Alcotest.fail "private requirement tag was expanded"

let test_private_error_union_is_refused () =
  let engine =
    resolve_exact
      {|
module Private_union = struct
  module Errors = struct
    type first = [ `Private_union_first ] [@@hamlet.subtractor.error_leaf.v1]
    type second = [ `Private_union_second ] [@@hamlet.subtractor.error_leaf.v1]
    type error = private [ first | second ] [@@hamlet.subtractor.error_union.v1]
  end

  let source : (unit, Errors.error, Hamlet.never) Hamlet.t =
    Hamlet.Combinators.return ()
end

let caught =
  Hamlet.Combinators.catch Private_union.source ~handler:(fun error ->
    match error with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:private-union"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Abstract_alias _ -> ()
  | _ -> Alcotest.fail "private generated error union was inspected"

let test_grouped_requirement_alias_refused () =
  let engine =
    resolve_exact
      {|
module Audit = struct
  module Tag = struct
    type t = unit
    type r = [ `Audit of t Hamlet.P.t ] [@@hamlet.subtractor.service_tag.v1]
    let give (_ : r) (_ : t) : 'r Hamlet.Dispatch.t = assert false
  end
end

module Grouped : sig
  type requirement = [ Logger.Tag.r | Audit.Tag.r ]
  val source : (unit, Hamlet.never, requirement) Hamlet.t
end = struct
  type requirement = [ Logger.Tag.r | Audit.Tag.r ]
  let source : (unit, Hamlet.never, requirement) Hamlet.t =
    Hamlet.Combinators.return ()
end

let provided =
  Hamlet.Combinators.provide Grouped.source ~handler:(fun requirement ->
    match requirement with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:grouped-alias"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Grouped_requirement _ -> ()
  | _ -> Alcotest.fail "grouped requirement alias lost its grouped refusal"

let test_outside_arm_reaches_universe_check () =
  let engine =
    resolve_exact
      {|
module Outside = struct
  module Errors = struct
    type outside = [ `Outside ] [@@hamlet.subtractor.error_leaf.v1]
  end
end

let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`Read 1 : Local_io.Errors.error)

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Outside.Errors.outside -> Hamlet.Combinators.return ()
    | #Local_io.Errors.read_error -> Hamlet.Combinators.return ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:outside-universe"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Leaf_outside_universe _ -> ()
  | _ -> Alcotest.fail "outside arm did not reach residual universe checking"

let test_principal_fail_is_exact () =
  let engine =
    resolve_exact
      {|
let source = Hamlet.Combinators.fail (`Read 1)

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:principal"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check int)
    "principal fail is exhausted" 0
    (Hamlet_subtractor_core.Residual.residual residual |> List.length)

let test_principal_chain_is_exact () =
  let engine =
    resolve_exact
      {|
let source =
  Hamlet.Combinators.chain Logger.Tag.summon ~handler:(fun _ ->
    Hamlet.Combinators.chain Clock.Tag.summon ~handler:(fun _ ->
      Hamlet.Combinators.return ()))

let provided =
  Hamlet.Combinators.provide source ~handler:(fun requirement ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:principal-chain"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "principal chain retains Clock" [ "Clock" ]
    (Hamlet_subtractor_core.Residual.residual residual |> leaf_labels)

let test_principal_local_builder_is_exact () =
  let engine =
    resolve_exact
      {|
let source () =
  Hamlet.Combinators.chain Logger.Tag.summon ~handler:(fun _ ->
    Hamlet.Combinators.chain Clock.Tag.summon ~handler:(fun _ ->
      Hamlet.Combinators.return ()))

let provided =
  Hamlet.Combinators.provide (source ()) ~handler:(fun requirement ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:principal-local-builder"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "principal local builder retains Clock" [ "Clock" ]
    (Hamlet_subtractor_core.Residual.residual residual |> leaf_labels)

let test_parameter_dependent_builder_is_refused () =
  let engine =
    resolve_exact
      {|
let source error = Hamlet.Combinators.fail error

let caught error =
  Hamlet.Combinators.catch (source error) ~handler:(fun current ->
    match current with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:parameter-dependent-builder"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Polymorphic_parameter
  | Hamlet_subtractor_core.Diagnostic.Higher_order_flow ->
      ()
  | _ -> Alcotest.fail "parameter-dependent builder was accepted as independent"

let test_parameter_alias_refused () =
  let engine =
    resolve_exact
      {|
let caught source =
  let alias = source in
  Hamlet.Combinators.catch alias ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:alias-parameter"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Polymorphic_parameter
  | Hamlet_subtractor_core.Diagnostic.Higher_order_flow ->
      ()
  | _ -> Alcotest.fail "parameter alias was accepted as independent"

let test_higher_order_binding_refused () =
  let engine =
    resolve_exact
      {|
let caught producer =
  let source = producer () in
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:higher-order"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Polymorphic_parameter
  | Hamlet_subtractor_core.Diagnostic.Higher_order_flow ->
      ()
  | _ -> Alcotest.fail "higher-order producer was accepted as independent"

let test_source_or_pattern_refused () =
  let engine =
    resolve_exact
      {|
let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t = assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | (#Local_io.Errors.read_error | #Local_io.Errors.read_error) ->
        Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:or-pattern"]))
|}
  in
  match refused_code engine with
  | Hamlet_subtractor_core.Diagnostic.Unsupported_pattern -> ()
  | _ -> Alcotest.fail "source or-pattern was accepted as a complete leaf"

let test_payload_module_alias_is_canonical () =
  let engine =
    resolve_exact
      {|
module Payload = struct type t = int end
module Payload_alias = Payload
module Payload_error = struct
  module Errors = struct
    type payload_error = [ `Payload of Payload.t ]
      [@@hamlet.subtractor.error_leaf.v1]
    type error = payload_error [@@hamlet.subtractor.error_union.v1]
  end
end

let source :
    (unit, [ `Payload of Payload_alias.t ], Hamlet.never) Hamlet.t =
  assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Payload_error.Errors.payload_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:payload-alias"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check int)
    "payload alias leaves no residual" 0
    (Hamlet_subtractor_core.Residual.residual residual |> List.length)

let test_recovery_fail_is_certified () =
  let engine =
    resolve_exact
      {|
let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t = assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.fail (`Other true)
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:recovery-fail"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "recovery errors join the propagated residual" [ "Other"; "Write" ]
    (Hamlet_subtractor_core.Residual.output residual |> leaf_labels)

let test_opaque_recovery_keeps_current_marker () =
  let engine =
    resolve_exact
      {|
let opaque_recovery () :
    (unit, [> `Opaque_recovery ], Hamlet.never) Hamlet.t =
  assert false

let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t = assert false

let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> opaque_recovery ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:opaque-recovery"]))
|}
  in
  let residual = resolved_residual engine in
  Alcotest.(check (list string))
    "current fallback still forwards the exact input residual" [ "Write" ]
    (Hamlet_subtractor_core.Residual.residual residual |> leaf_labels)

let test_recovery_requirement_flows_to_dependent_marker () =
  let engine =
    resolve_exact
      {|
let source = Hamlet.Combinators.fail (`Read 1)

let recovered =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Logger.Tag.summon
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:summon-recovery"]))

let provided =
  Hamlet.Combinators.provide recovered ~handler:(fun requirement ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:after-recovery"]))
|}
  in
  let outcomes = Hamlet_subtractor_engine.outcomes engine in
  Alcotest.(check int) "two resolved markers" 2 (List.length outcomes);
  List.iter
    (function
      | _, Hamlet_subtractor_core.Protocol.Resolved _ -> ()
      | _, Hamlet_subtractor_core.Protocol.Refused diagnostic ->
          Alcotest.fail (Hamlet_subtractor_core.Diagnostic.message diagnostic))
    outcomes

let test_nested_recovery_requirement_pipeline () =
  let engine =
    resolve_exact
      {|
let source = Hamlet.Combinators.fail (`Read 1)

let provided =
  source
  |> Hamlet.Combinators.catch ~handler:(fun error ->
       match error with
       | #Local_io.Errors.read_error ->
           Hamlet.Combinators.summon Logger.Tag.key Logger.Tag.tag
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:nested-recovery"]))
  |> Hamlet.Combinators.provide ~handler:(fun requirement ->
       match requirement with
       | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:nested-provide"]))
|}
  in
  let outcomes = Hamlet_subtractor_engine.outcomes engine in
  Alcotest.(check int) "two nested markers" 2 (List.length outcomes);
  List.iter
    (function
      | _, Hamlet_subtractor_core.Protocol.Resolved _ -> ()
      | _, Hamlet_subtractor_core.Protocol.Refused diagnostic ->
          Alcotest.fail (Hamlet_subtractor_core.Diagnostic.message diagnostic))
    outcomes

let require_one_dependent_refusal engine =
  let resolved, refused =
    Hamlet_subtractor_engine.outcomes engine
    |> List.partition (function
      | _, Hamlet_subtractor_core.Protocol.Resolved _ -> true
      | _, Hamlet_subtractor_core.Protocol.Refused _ -> false)
  in
  Alcotest.(check int) "one exact inner marker" 1 (List.length resolved);
  Alcotest.(check int) "one refused dependent marker" 1 (List.length refused)

let test_summon_fake_key_is_opaque () =
  resolve_exact
    {|
let fake_key : Logger.Tag.t Hamlet.Service_key.t =
  Hamlet.Service_key.make ~name:"Fake_logger"

let source = Hamlet.Combinators.fail (`Read 1)

let provided =
  source
  |> Hamlet.Combinators.catch ~handler:(fun error ->
       match error with
       | #Local_io.Errors.read_error ->
           Hamlet.Combinators.summon fake_key Logger.Tag.tag
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:fake-key"]))
  |> Hamlet.Combinators.provide ~handler:(fun requirement ->
       match requirement with
       | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:after-fake-key"]))
|}
  |> require_one_dependent_refusal

let test_summon_lookalike_callee_is_opaque () =
  resolve_exact
    {|
module Lookalike = struct
  let summon = Hamlet.Combinators.summon
end

let source = Hamlet.Combinators.fail (`Read 1)

let provided =
  source
  |> Hamlet.Combinators.catch ~handler:(fun error ->
       match error with
       | #Local_io.Errors.read_error ->
           Lookalike.summon Logger.Tag.key Logger.Tag.tag
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:lookalike-summon"]))
  |> Hamlet.Combinators.provide ~handler:(fun requirement ->
       match requirement with
       | #Logger.Tag.r as witness -> Logger.Tag.give witness ()
       | _ -> (assert false [@hamlet.subtractor.marker.v1 "s:after-lookalike"]))
|}
  |> require_one_dependent_refusal

let test_let_bound_marker_dependency_is_followed () =
  let engine =
    resolve_exact
      {|
let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t = assert false

let inner =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:inner"]))

let outer =
  Hamlet.Combinators.catch inner ~handler:(fun error ->
    match error with
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:outer"]))
|}
  in
  let input_sizes =
    Hamlet_subtractor_engine.outcomes engine
    |> List.map (function
      | _, Hamlet_subtractor_core.Protocol.Resolved residual ->
          Hamlet_subtractor_core.Residual.input residual
          |> Hamlet_subtractor_core.Proof.leaves
          |> List.length
      | _, Hamlet_subtractor_core.Protocol.Refused diagnostic ->
          Alcotest.fail (Hamlet_subtractor_core.Diagnostic.message diagnostic))
    |> List.sort Int.compare
  in
  Alcotest.(check (list int))
    "outer input comes from inner residual certificate" [ 1; 2 ] input_sizes

let test_tool_modes_have_identical_evidence () =
  let source =
    {|
let source : (unit, Local_io.Errors.error, Hamlet.never) Hamlet.t = assert false
let caught =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Local_io.Errors.read_error -> Hamlet.Combinators.success ()
    | _ -> (assert false [@hamlet.subtractor.marker.v1 "e:tool-parity"]))
|}
  in
  let byte = resolve_exact ~tool_name:"ocamlc" source in
  let native = resolve_exact ~tool_name:"ocamlopt" source in
  Alcotest.(check bool)
    "mode-independent outcomes" true
    (Hamlet_subtractor_engine.outcomes byte = Hamlet_subtractor_engine.outcomes native);
  Alcotest.(check bool)
    "mode-independent catalogues" true
    (Hamlet_subtractor_engine.catalogues byte = Hamlet_subtractor_engine.catalogues native)

let () =
  Alcotest.run "hamlet elaboration private bridge"
    [
      ( "compiler session",
        [
          Alcotest.test_case "ocamldep skips typing" `Quick
            test_ocamldep_skips_typing;
          Alcotest.test_case "repeated sessions are isolated" `Quick
            test_repeated_sessions;
          Alcotest.test_case "failure does not poison the next session" `Quick
            test_failure_does_not_poison_next_session;
          Alcotest.test_case "fresh store resolves sibling CMI" `Quick
            test_fresh_store_resolves_sibling_cmi;
          Alcotest.test_case "warning state is scoped" `Quick
            test_warning_state_is_scoped;
          Alcotest.test_case "resolver request is correlated" `Quick
            test_resolve_request_success_and_correlation;
        ] );
      ( "probe ownership",
        [
          Alcotest.test_case "same-span IDs are deterministic" `Quick
            test_same_span_ids_are_deterministic;
          Alcotest.test_case "source edits invalidate marker IDs" `Quick
            test_source_edit_changes_marker_id;
          Alcotest.test_case "inline upstream gets a synthetic let" `Quick
            test_inline_upstream_is_isolated;
          Alcotest.test_case "private refusals are structured" `Quick
            test_private_owner_refusals;
          Alcotest.test_case "wrong channel is refused before typing" `Quick
            test_wrong_channel_is_refused_before_typing;
          Alcotest.test_case "direct and pipe owners are recognized" `Quick
            test_direct_and_pipe_owners;
          Alcotest.test_case "nested owners keep distinct IDs" `Quick
            test_nested_owners_keep_distinct_ids;
          Alcotest.test_case "refused markers stay outside typed lookup" `Quick
            test_refused_marker_is_not_a_typed_lookup_failure;
        ] );
      ( "exact evidence",
        [
          Alcotest.test_case "closed local catch is exact" `Quick
            test_exact_local_catch;
          Alcotest.test_case "Cases subsets stay nominal" `Quick
            test_exact_cases_subset;
          Alcotest.test_case "transparent aliases stay structural" `Quick
            test_transparent_alias_stays_structural;
          Alcotest.test_case "singleton provide is exact" `Quick
            test_exact_requirement_provide;
          Alcotest.test_case "fake Hamlet callee is refused" `Quick
            test_fake_callee_refused;
          Alcotest.test_case "open parameter row is refused" `Quick
            test_parameter_row_refused;
          Alcotest.test_case "hidden aliases stay abstract" `Quick
            test_hidden_alias_refused_as_abstract;
          Alcotest.test_case "private leaf aliases stay abstract" `Quick
            test_private_leaf_aliases_are_refused;
          Alcotest.test_case "private error unions stay abstract" `Quick
            test_private_error_union_is_refused;
          Alcotest.test_case "grouped requirements stay grouped" `Quick
            test_grouped_requirement_alias_refused;
          Alcotest.test_case "outside arms reach universe checks" `Quick
            test_outside_arm_reaches_universe_check;
          Alcotest.test_case "principal fail is exact" `Quick
            test_principal_fail_is_exact;
          Alcotest.test_case "principal chain is exact" `Quick
            test_principal_chain_is_exact;
          Alcotest.test_case "principal local builder is exact" `Quick
            test_principal_local_builder_is_exact;
          Alcotest.test_case "parameter-dependent builder is refused" `Quick
            test_parameter_dependent_builder_is_refused;
          Alcotest.test_case "parameter aliases are refused" `Quick
            test_parameter_alias_refused;
          Alcotest.test_case "higher-order bindings are refused" `Quick
            test_higher_order_binding_refused;
          Alcotest.test_case "source or-patterns are refused" `Quick
            test_source_or_pattern_refused;
          Alcotest.test_case "payload aliases are canonical" `Quick
            test_payload_module_alias_is_canonical;
          Alcotest.test_case "fail recovery is certified" `Quick
            test_recovery_fail_is_certified;
          Alcotest.test_case "opaque recovery keeps current marker" `Quick
            test_opaque_recovery_keeps_current_marker;
          Alcotest.test_case "recovery requirement reaches dependency" `Quick
            test_recovery_requirement_flows_to_dependent_marker;
          Alcotest.test_case "nested recovery reaches provide" `Quick
            test_nested_recovery_requirement_pipeline;
          Alcotest.test_case "summon fake key stays opaque" `Quick
            test_summon_fake_key_is_opaque;
          Alcotest.test_case "summon lookalike stays opaque" `Quick
            test_summon_lookalike_callee_is_opaque;
          Alcotest.test_case "let-bound marker dependency is followed" `Quick
            test_let_bound_marker_dependency_is_followed;
          Alcotest.test_case "compiler modes have identical evidence" `Quick
            test_tool_modes_have_identical_evidence;
        ] );
    ]
