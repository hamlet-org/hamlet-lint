open Ppxlib
open Hamlet_subtractor_core

module Generic_contract = Hamlet_subtractor_generic_contract
module Generic_definition = Hamlet_subtractor_generic_definition

let activate_probe_phase () = Ppx_hamlet.subtractor_phase := Ppx_hamlet.Probe

let reset_phase () = Ppx_hamlet.subtractor_phase := Ppx_hamlet.Normal

let before _context structure =
  activate_probe_phase ();
  structure

let fallback_parts = function
  | Kind.Error -> ("[%hamlet.te ...]", "[%hamlet.propagate_e]")
  | Kind.Requirement -> ("[%hamlet.ts ...]", "[%hamlet.propagate_s]")

let probe_marker_kind (marker : Hamlet_subtractor_probe.marker) =
  match marker.kind with
  | Hamlet_subtractor_probe.Error_propagation -> Kind.Error
  | Hamlet_subtractor_probe.Requirement_propagation -> Kind.Requirement

let marker_fallback_for_kind kind =
  let annotation, propagation = fallback_parts kind in
  Printf.sprintf "use an explicit %s input universe with %s" annotation
    propagation

let marker_fallback marker =
  marker |> probe_marker_kind |> marker_fallback_for_kind

let auto_marker_spelling = function
  | Hamlet_subtractor_probe.Error_propagation -> "[%hamlet.propagate_e.auto]"
  | Hamlet_subtractor_probe.Requirement_propagation ->
      "[%hamlet.propagate_s.auto]"

let owner_name = function
  | Hamlet_subtractor_probe.Error_propagation -> "Combinators.catch"
  | Hamlet_subtractor_probe.Requirement_propagation -> "Combinators.provide"

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else loop (index + 1)
  in
  loop 0

let with_marker_fallback kind message =
  let annotation, propagation = fallback_parts kind in
  match (contains message annotation, contains message propagation) with
  | true, true -> message
  | true, false ->
      Printf.sprintf "%s; replace the auto marker with %s" message propagation
  | false, true ->
      Printf.sprintf "%s; add an explicit %s input universe" message annotation
  | false, false ->
      Printf.sprintf "%s; %s" message (marker_fallback_for_kind kind)

let probe_refusal_message (refusal : Hamlet_subtractor_probe.refusal) =
  match refusal.reason with
  | Hamlet_subtractor_probe.Wrong_channel { owner; marker = _ } ->
      Printf.sprintf "kind mismatch: %s requires %s" (owner_name owner)
        (auto_marker_spelling owner)
  | reason ->
      let reason =
        match reason with
        | Hamlet_subtractor_probe.No_supported_owner ->
            "the marker is not owned by a direct Combinators.catch or \
             Combinators.provide call"
        | Hamlet_subtractor_probe.Named_handler ->
            "automatic propagation currently requires an inline handler"
        | Hamlet_subtractor_probe.Ambiguous_owner ->
            "the handler is shared by more than one possible owner"
        | Hamlet_subtractor_probe.Unsupported_call_shape ->
            "the owning combinator call has an unsupported argument shape"
        | Hamlet_subtractor_probe.Wrong_channel _ -> assert false
      in
      reason ^ "; " ^ marker_fallback refusal.marker

let marker_for_id prepared id =
  prepared.Hamlet_subtractor_probe.markers
  |> List.find_opt (fun (marker : Hamlet_subtractor_probe.marker) ->
      String.equal marker.id (Marker.id_to_string id))

let marker_for_string_id prepared id =
  prepared.Hamlet_subtractor_probe.markers
  |> List.find_opt (fun (marker : Hamlet_subtractor_probe.marker) ->
      String.equal marker.id id)

let first_marker prepared =
  match prepared.Hamlet_subtractor_probe.markers with
  | (marker : Hamlet_subtractor_probe.marker) :: _ -> Some marker
  | [] -> None

let first_marker_loc prepared =
  first_marker prepared
  |> Option.fold ~none:Location.none
       ~some:(fun (marker : Hamlet_subtractor_probe.marker) -> marker.loc)

let first_some left right = match left with Some _ -> left | None -> right

let fast_pipeline_message marker =
  "automatic propagation requires Dune's classic PPX pipeline; configure \
   (staged_pps hamlet-subtractor.ppx), not (pps hamlet-subtractor.ppx); "
  ^ marker_fallback marker

type tool_mode = Dependency_scan | Exact_elaboration | Fast_pipeline | Unknown

let tool_mode = function
  | "ocamldep" -> Dependency_scan
  | "ocamlc" | "ocamlopt" | "merlin" -> Exact_elaboration
  | "dune" | "ppx_driver" | "ppxlib_driver" -> Fast_pipeline
  | _ -> Unknown

let unknown_tool_message marker tool_name =
  Printf.sprintf
    "automatic propagation cannot prove that PPX tool context %S performs a \
     final compiler or Merlin type-check; %s"
    tool_name (marker_fallback marker)

let compiler_refusal_marker prepared = function
  | Hamlet_subtractor_compiler_compat.Evidence_failed refusal ->
      let id =
        refusal.Hamlet_subtractor_compiler_evidence.marker |> Marker.id
      in
      first_some (marker_for_id prepared id) (first_marker prepared)
  | Hamlet_subtractor_compiler_compat.Generic_evidence_failed _ ->
      first_marker prepared
  | Hamlet_subtractor_compiler_compat.Dependency_scan
  | Hamlet_subtractor_compiler_compat.Unsupported_tool _
  | Hamlet_subtractor_compiler_compat.Typing_failed _
  | Hamlet_subtractor_compiler_compat.Probe_lookup_failed _
  | Hamlet_subtractor_compiler_compat.Request_context_mismatch _
  | Hamlet_subtractor_compiler_compat.Probe_ast_failed _
  | Hamlet_subtractor_compiler_compat.Protocol_construction_failed _
  | Hamlet_subtractor_compiler_compat.Protocol_correlation_failed _ ->
      first_marker prepared

let compiler_refusal_loc prepared refusal =
  compiler_refusal_marker prepared refusal
  |> Option.fold ~none:Location.none
       ~some:(fun (marker : Hamlet_subtractor_probe.marker) -> marker.loc)

let compiler_refusal_reason = function
  | Hamlet_subtractor_compiler_compat.Dependency_scan ->
      "dependency scans do not perform exact elaboration"
  | Hamlet_subtractor_compiler_compat.Unsupported_tool tool ->
      "automatic propagation is unavailable through the " ^ tool
      ^ " PPX pipeline"
  | Hamlet_subtractor_compiler_compat.Typing_failed _ ->
      "the temporary probe did not type-check in the active compilation context"
  | Hamlet_subtractor_compiler_compat.Probe_lookup_failed _ ->
      "the typed probe did not preserve every required marker link"
  | Hamlet_subtractor_compiler_compat.Evidence_failed refusal ->
      Hamlet_subtractor_compiler_evidence.refusal_message refusal
  | Hamlet_subtractor_compiler_compat.Generic_evidence_failed refusal ->
      Hamlet_subtractor_compiler_evidence.generic_refusal_message refusal
  | Hamlet_subtractor_compiler_compat.Request_context_mismatch
      { field; expected; actual } ->
      Printf.sprintf
        "the resolver context field %s differs: expected %s, received %s" field
        expected actual
  | Hamlet_subtractor_compiler_compat.Probe_ast_failed _ ->
      "the resolver binary probe AST could not be validated"
  | Hamlet_subtractor_compiler_compat.Protocol_construction_failed _ ->
      "the resolver could not construct a validated response"
  | Hamlet_subtractor_compiler_compat.Protocol_correlation_failed _ ->
      "the resolver response does not correlate with the current marker set"

let compiler_refusal_message prepared refusal =
  let reason = compiler_refusal_reason refusal in
  compiler_refusal_marker prepared refusal
  |> Option.fold ~none:reason ~some:(fun marker ->
      with_marker_fallback (probe_marker_kind marker) reason)

let replacement_marker prepared = function
  | Hamlet_subtractor_replace.Missing_outcome id ->
      marker_for_string_id prepared id
  | Hamlet_subtractor_replace.Missing_certificate id
  | Hamlet_subtractor_replace.Missing_owner id
  | Hamlet_subtractor_replace.Duplicate_owner id
  | Hamlet_subtractor_replace.Missing_upstream id
  | Hamlet_subtractor_replace.Duplicate_upstream id
  | Hamlet_subtractor_replace.Missing_marker_case id
  | Hamlet_subtractor_replace.Duplicate_marker_case id ->
      marker_for_id prepared id
  | Hamlet_subtractor_replace.Refused diagnostic ->
      diagnostic |> Diagnostic.marker |> Marker.id |> marker_for_id prepared
  | Hamlet_subtractor_replace.Generation_failed (marker, _) ->
      marker |> Marker.id |> marker_for_id prepared
  | Hamlet_subtractor_replace.Unmaterializable_certificate (marker, _) ->
      marker |> Marker.id |> marker_for_id prepared

let replacement_marker_or_first prepared error =
  first_some (replacement_marker prepared error) (first_marker prepared)

let replacement_loc prepared error =
  replacement_marker_or_first prepared error
  |> Option.fold ~none:Location.none
       ~some:(fun (marker : Hamlet_subtractor_probe.marker) -> marker.loc)

let replacement_message prepared error =
  let reason = Hamlet_subtractor_replace.error_message error in
  replacement_marker_or_first prepared error
  |> Option.fold ~none:reason ~some:(fun marker ->
      with_marker_fallback (probe_marker_kind marker) reason)

let location_of_span span =
  let file = Source_span.file span in
  let position ~line ~column ~offset =
    {
      Lexing.pos_fname = file;
      pos_lnum = line;
      pos_bol = offset - column;
      pos_cnum = offset;
    }
  in
  {
    Location.loc_start =
      position
        ~line:(Source_span.start_line span)
        ~column:(Source_span.start_column span)
        ~offset:(Source_span.start_offset span);
    loc_end =
      position
        ~line:(Source_span.end_line span)
        ~column:(Source_span.end_column span)
        ~offset:(Source_span.end_offset span);
    loc_ghost = false;
  }

let resolver_error_loc prepared = function
  | Hamlet_subtractor_resolver_client.Transport_failed
      (Hamlet_subtractor_resolver_transport.Remote_typing_failure
         { location = Some span; _ }) ->
      location_of_span span
  | Hamlet_subtractor_resolver_client.Ast_serialization_failed _
  | Hamlet_subtractor_resolver_client.Protocol_construction_failed _
  | Hamlet_subtractor_resolver_client.Transport_failed _ ->
      first_marker_loc prepared

let resolve ~context structure =
  let structure = Hamlet_subtractor_generic_definition.rewrite_exn structure in
  let definition_expectations =
    match
      Hamlet_subtractor_generic_contract.definition_expectations structure
    with
    | Ok expectations -> expectations
    | Error message ->
        Location.raise_errorf
          "generic automatic propagation contract preparation failed: %s"
          message
  in
  let tool_name = Expansion_context.Base.tool_name context in
  if tool_mode tool_name = Dependency_scan then
    structure
    |> Hamlet_subtractor_replace.strip_probe_attributes
    |> Hamlet_subtractor_generic_definition.strip_linkage_attributes
  else
    let prepared = Hamlet_subtractor_probe.prepare structure in
    let generic_calls =
      Hamlet_subtractor_generic_call.prepare prepared.probe_structure
    in
    (match generic_calls.refusals with
    | refusal :: _ ->
        Location.raise_errorf ~loc:refusal.loc
          "generic automatic propagation call is invalid: %s"
          (Hamlet_subtractor_generic_call.refusal_message refusal.reason)
    | [] -> ());
    let call_expectations =
      match Hamlet_subtractor_generic_call.expectations generic_calls with
      | Ok expectations -> expectations
      | Error message ->
          Location.raise_errorf
            "generic automatic propagation call preparation failed: %s" message
    in
    let generic_expectations = definition_expectations @ call_expectations in
    let has_generic = generic_expectations <> [] in
    let prepared =
      {
        prepared with
        probe_structure = generic_calls.probe_structure;
        structure = generic_calls.probe_structure;
      }
    in
    match (prepared.markers, has_generic) with
    | [], false -> prepared.base_structure
    | marker :: _, _ when tool_mode tool_name = Fast_pipeline ->
        Location.raise_errorf ~loc:marker.loc "%s"
          (fast_pipeline_message marker)
    | [], true when tool_mode tool_name = Fast_pipeline ->
        Location.raise_errorf
          "generic automatic propagation requires Dune's classic PPX pipeline; \
           configure (staged_pps hamlet-subtractor.ppx), not (pps \
           hamlet-subtractor.ppx)"
    | marker :: _, _ when tool_mode tool_name = Unknown ->
        Location.raise_errorf ~loc:marker.loc "%s"
          (unknown_tool_message marker tool_name)
    | [], true when tool_mode tool_name = Unknown ->
        Location.raise_errorf
          "generic automatic propagation cannot prove that PPX tool context %S \
           performs a final compiler or Merlin type-check"
          tool_name
    | _ -> (
        match prepared.refusals with
        | refusal :: _ ->
            Location.raise_errorf ~loc:refusal.loc
              "automatic propagation cannot be resolved: %s"
              (probe_refusal_message refusal)
        | [] -> (
            let source_file = Expansion_context.Base.input_name context in
            if String.trim source_file = "" || String.equal source_file "_none_"
            then
              match first_marker prepared with
              | Some marker ->
                  Location.raise_errorf ~loc:marker.loc "%s"
                    (with_marker_fallback (probe_marker_kind marker)
                       "automatic propagation requires the active source \
                        filename from the PPX context")
              | None ->
                  Location.raise_errorf
                    "generic automatic propagation requires the active source \
                     filename from the PPX context"
            else
              match
                Hamlet_subtractor_resolver_client.resolve_elaboration
                  ~generic_expectations ~tool_name ~source_file prepared
              with
              | Error error ->
                  Location.raise_errorf
                    ~loc:(resolver_error_loc prepared error)
                    "automatic propagation resolver failed: %s; %s"
                    (Hamlet_subtractor_resolver_client.message error)
                    (first_marker prepared
                    |> Option.map marker_fallback
                    |> Option.value
                         ~default:"use an explicit propagation input universe")
              | Ok resolution -> (
                  let engine = resolution.engine in
                  match
                    Hamlet_subtractor_replace.structure
                      ~catalogues:(Hamlet_subtractor_engine.catalogues engine)
                      ~outcomes:(Hamlet_subtractor_engine.outcomes engine)
                      ~resolved_values:
                        (Hamlet_subtractor_engine.resolved_values engine)
                      prepared.base_structure
                  with
                  | Ok structure -> (
                      match
                        Hamlet_subtractor_generic_contract.finalize_definitions
                          ~attachments:resolution.generic_attachments structure
                      with
                      | Error message ->
                          Location.raise_errorf
                            "generic automatic propagation finalization \
                             failed: %s"
                            message
                      | Ok structure -> (
                          match
                            Hamlet_subtractor_generic_definition
                            .finalize_composition
                              ~attachments:resolution.generic_attachments
                              structure
                          with
                          | Error error ->
                              Location.raise_errorf
                                "generic automatic propagation composition \
                                 finalization failed: %s"
                                (Hamlet_subtractor_generic_definition
                                 .composition_finalization_error_message error)
                          | Ok structure ->
                              let structure =
                                Hamlet_subtractor_generic_definition
                                .strip_linkage_attributes structure
                              in
                              begin match
                                Hamlet_subtractor_generic_call.finalize
                                  ~calls:generic_calls.calls
                                  ~attachments:resolution.generic_attachments
                                  ~catalogues:
                                    (Hamlet_subtractor_engine.catalogues engine)
                                  structure
                              with
                              | Ok structure -> structure
                              | Error error ->
                                  Location.raise_errorf
                                    "generic automatic propagation call \
                                     finalization failed: %s"
                                    (Hamlet_subtractor_generic_call
                                     .finalization_error_message error)
                              end))
                  | Error error ->
                      Location.raise_errorf
                        ~loc:(replacement_loc prepared error)
                        "automatic propagation elaboration failed: %s"
                        (replacement_message prepared error))))

let after context structure =
  Fun.protect ~finally:reset_phase (fun () -> resolve ~context structure)

let () =
  let before = Driver.Instrument.V2.make before ~position:Before in
  Driver.V2.register_transformation "hamlet.subtractor.probe" ~instrument:before;
  let after = Driver.Instrument.V2.make after ~position:After in
  Driver.V2.register_transformation "hamlet.subtractor.final" ~instrument:after
