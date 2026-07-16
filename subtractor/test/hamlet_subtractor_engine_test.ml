module Compiler_pprintast = Pprintast

open Ppxlib
open Hamlet_subtractor_core

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.fail (label ^ " unexpectedly failed")

let identity ?(module_path = [ "Fixture" ]) name =
  Identity.make ~module_path ~declaration_name:name ~interface_digest:"digest"
  |> get_ok "identity"

let atom ?(kind = Kind.Error) declaration label payload =
  Atom.make ~kind ~declaration ~label ~payload |> get_ok "atom"

let error_leaf ?(materialization = Leaf.Direct) name label =
  let identity = identity ~module_path:[ "Service"; "Errors" ] name in
  let member = atom identity label Atom.No_payload in
  Leaf.error ~identity ~members:[ member ] ~materialization
  |> get_ok "error leaf"

let requirement_leaf ?(materialization = Leaf.Requirement_tag) name label =
  let identity = identity ~module_path:[ name; "Tag" ] "r" in
  let member = atom ~kind:Kind.Requirement identity label Atom.No_payload in
  Leaf.requirement ~identity ~member ~materialization
  |> get_ok "requirement leaf"

let proof kind leaves =
  Proof.create ~kind ~origin:Proof.Closed_row ~leaves |> get_ok "proof"

let residual ?(arms = []) input =
  Residual.calculate ~input ~arms ~recovery:[] |> get_ok "residual"

let empty_proof kind = proof kind []

let resolved_value residual =
  let output = proof (Residual.kind residual) (Residual.output residual) in
  let errors, requirements =
    match Residual.kind residual with
    | Kind.Error ->
        ( Effect_certificate.exact output,
          Effect_certificate.exact (empty_proof Kind.Requirement) )
    | Kind.Requirement ->
        ( Effect_certificate.exact (empty_proof Kind.Error),
          Effect_certificate.exact output )
  in
  let certificate =
    Effect_certificate.create ~errors ~requirements |> get_ok "certificate"
  in
  Hamlet_subtractor_engine.{ residual; certificate }

let print_cases cases =
  let loc = Location.none in
  let expression = Ast_builder.Default.pexp_function_cases ~loc cases in
  let structure = [ Ast_builder.Default.pstr_eval ~loc expression [] ] in
  let structure = Selected_ast.to_ocaml Selected_ast.Type.Structure structure in
  Format.asprintf "%a" Compiler_pprintast.structure structure

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else loop (index + 1)
  in
  loop 0

let count_occurrences text fragment =
  let fragment_length = String.length fragment in
  let rec loop index count =
    if index + fragment_length > String.length text then count
    else if String.sub text index fragment_length = fragment then
      loop (index + fragment_length) (count + 1)
    else loop (index + 1) count
  in
  loop 0 0

let catalogue_identity =
  identity ~module_path:[ "Service"; "Errors"; "Cases" ] "t"

let union_identity = identity ~module_path:[ "Service"; "Errors" ] "error"

let cases_leaf name label field =
  let leaf_identity = identity ~module_path:[ "Service"; "Errors" ] name in
  let member = atom leaf_identity label Atom.No_payload in
  Leaf.error ~identity:leaf_identity ~members:[ member ]
    ~materialization:
      (Leaf.Error_cases
         { catalogue = catalogue_identity; union = union_identity; field })
  |> get_ok "cases leaf"

let cases_fixture () =
  let first = cases_leaf "first_error" "First" "first_error" in
  let second = cases_leaf "second_error" "Second" "second_error" in
  let third = cases_leaf "third_error" "Third" "third_error" in
  let fields =
    [
      Hamlet_subtractor_catalogue.
        { name = "first_error"; leaf = Leaf.identity first };
      Hamlet_subtractor_catalogue.
        { name = "second_error"; leaf = Leaf.identity second };
      Hamlet_subtractor_catalogue.
        { name = "third_error"; leaf = Leaf.identity third };
    ]
  in
  let catalogue =
    Hamlet_subtractor_catalogue.create ~identity:catalogue_identity
      ~union:union_identity ~fields
    |> get_ok "catalogue"
  in
  (catalogue, first, second, third)

let generated ?(catalogues = []) residual =
  Hamlet_subtractor_generator.cases ~loc:Location.none ~catalogues residual
  |> get_ok "generation"

let generated_layer ?(catalogues = []) residual =
  Hamlet_subtractor_generator.cases ~loc:Location.none ~catalogues
    ~forwarding:(Hamlet_subtractor_generator.Layer_fail_like "primary_once")
    residual
  |> get_ok "Layer generation"

let generated_at ?(catalogues = []) loc residual =
  Hamlet_subtractor_generator.cases ~loc ~catalogues residual
  |> get_ok "generation"

let test_layer_fail_like_generation () =
  let direct = error_leaf "direct_error" "Direct" in
  let structural =
    error_leaf ~materialization:Leaf.Structural_variant "structural_error"
      "Structural"
  in
  let direct_cases =
    residual (proof Kind.Error [ direct; structural ])
    |> generated_layer
    |> print_cases
  in
  Alcotest.(check int)
    "two direct fail_like calls" 2
    (count_occurrences direct_cases "Hamlet.Layer.fail_like primary_once");
  Alcotest.(check int)
    "no effect fail calls" 0
    (count_occurrences direct_cases "Hamlet.Combinators.fail");
  let catalogue, first, second, third = cases_fixture () in
  let arms =
    [
      Residual.arm
        ~target:(Residual.Complete_leaf (Leaf.identity first))
        ~guard:Residual.Unguarded ~action:Residual.Handle;
    ]
  in
  let catalogue_cases =
    residual ~arms (proof Kind.Error [ first; second; third ])
    |> generated_layer ~catalogues:[ catalogue ]
    |> print_cases
  in
  Alcotest.(check int)
    "two catalogue fail_like callbacks" 2
    (count_occurrences catalogue_cases "Hamlet.Layer.fail_like primary_once");
  Alcotest.(check int)
    "Layer avoids effect-only catalogue dispatch" 0
    (count_occurrences catalogue_cases "Cases.dispatch")

let test_position offset =
  {
    Lexing.pos_fname = "generator_location.ml";
    pos_lnum = 3;
    pos_bol = 40;
    pos_cnum = offset;
  }

let test_location start_offset end_offset =
  {
    Location.loc_start = test_position start_offset;
    loc_end = test_position end_offset;
    loc_ghost = false;
  }

let check_marker_span label expected actual =
  Alcotest.(check int)
    (label ^ " start") expected.Location.loc_start.pos_cnum
    actual.Location.loc_start.pos_cnum;
  Alcotest.(check int)
    (label ^ " end") expected.loc_end.pos_cnum actual.loc_end.pos_cnum;
  Alcotest.(check bool) (label ^ " is source") false actual.loc_ghost

let check_ghost_subtree pattern expression =
  let non_ghost = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! pattern pattern =
        if not pattern.ppat_loc.loc_ghost then
          non_ghost := "pattern" :: !non_ghost;
        super#pattern pattern

      method! expression expression =
        if not expression.pexp_loc.loc_ghost then
          non_ghost := "expression" :: !non_ghost;
        super#expression expression
    end
  in
  iterator#pattern pattern;
  iterator#expression expression;
  Alcotest.(check (list string)) "nested nodes are ghost" [] !non_ghost

let check_refutation_case label case =
  begin match case.pc_lhs.ppat_desc with
  | Ppat_any -> ()
  | _ -> Alcotest.fail (label ^ " does not use a wildcard pattern")
  end;
  begin match case.pc_rhs.pexp_desc with
  | Pexp_unreachable -> ()
  | _ -> Alcotest.fail (label ^ " is not a refutation case")
  end;
  Alcotest.(check bool)
    (label ^ " pattern is ghost")
    true case.pc_lhs.ppat_loc.loc_ghost;
  Alcotest.(check bool)
    (label ^ " expression is ghost")
    true case.pc_rhs.pexp_loc.loc_ghost

let test_generated_locations_keep_only_outer_marker_real () =
  let loc = test_location 51 80 in
  let direct = error_leaf "location_error" "Location_error" in
  let direct_case =
    residual (proof Kind.Error [ direct ]) |> generated_at loc |> List.hd
  in
  check_marker_span "direct case" loc direct_case.pc_lhs.ppat_loc;
  begin match direct_case.pc_lhs.ppat_desc with
  | Ppat_alias (nested, name) ->
      Alcotest.(check bool) "alias name is ghost" true name.loc.loc_ghost;
      check_ghost_subtree nested direct_case.pc_rhs
  | _ -> Alcotest.fail "expected a named direct propagation pattern"
  end;
  let catalogue, first, second, third = cases_fixture () in
  let input = proof Kind.Error [ first; second; third ] in
  let handled =
    Residual.arm
      ~target:(Complete_leaf (Leaf.identity first))
      ~guard:Unguarded ~action:Handle
  in
  let dispatch_case =
    residual ~arms:[ handled ] input
    |> generated_at ~catalogues:[ catalogue ] loc
    |> List.hd
  in
  check_marker_span "dispatch case" loc dispatch_case.pc_lhs.ppat_loc;
  begin match dispatch_case.pc_lhs.ppat_desc with
  | Ppat_alias (nested, _) -> check_ghost_subtree nested dispatch_case.pc_rhs
  | _ -> Alcotest.fail "expected the linear dispatch propagation pattern"
  end;
  let callbacks = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        begin match expression.pexp_desc with
        | Pexp_function (_ :: _, _, _) ->
            incr callbacks;
            Alcotest.(check bool)
              "callback is ghost" true expression.pexp_loc.loc_ghost
        | _ -> ()
        end;
        super#expression expression
    end
  in
  iterator#expression dispatch_case.pc_rhs;
  Alcotest.(check bool) "generated a Cases callback" true (!callbacks > 0)

let test_error_and_requirement_generation () =
  let error = error_leaf "read_error" "Read" in
  let error_text =
    residual (proof Kind.Error [ error ]) |> generated |> print_cases
  in
  Alcotest.(check bool)
    "fail arm" true
    (contains error_text "Hamlet.Combinators.fail error");
  let requirement = requirement_leaf "Logger" "Logger" in
  let requirement_text =
    residual (proof Kind.Requirement [ requirement ])
    |> generated
    |> print_cases
  in
  Alcotest.(check bool)
    "need arm" true
    (contains requirement_text "Hamlet.Dispatch.need witness")

let test_nonempty_generation_appends_refutation_guard () =
  let error = error_leaf "guarded_error" "Guarded" in
  let cases = residual (proof Kind.Error [ error ]) |> generated in
  Alcotest.(check int) "forwarding plus guard" 2 (List.length cases);
  cases |> List.rev |> List.hd |> check_refutation_case "final guard"

let test_structural_arity () =
  let declaration = identity "inline" in
  let constant_atom = atom declaration "Constant" Atom.No_payload in
  let payload_atom =
    atom declaration "Payload" (Atom.Payload (Type_identity.primitive Int))
  in
  let leaf identity atom =
    Leaf.error ~identity ~members:[ atom ]
      ~materialization:Leaf.Structural_variant
    |> get_ok "structural leaf"
  in
  let constant = leaf (identity "constant") constant_atom in
  let payload = leaf (identity "payload") payload_atom in
  let text =
    residual (proof Kind.Error [ constant; payload ])
    |> generated
    |> print_cases
  in
  Alcotest.(check bool) "constant pattern" true (contains text "`Constant as");
  Alcotest.(check bool) "payload pattern" true (contains text "`Payload _ as")

let test_cases_is_one_linear_dispatch () =
  let catalogue, first, second, third = cases_fixture () in
  let input = proof Kind.Error [ first; second; third ] in
  let arm =
    Residual.arm
      ~target:(Complete_leaf (Leaf.identity first))
      ~guard:Unguarded ~action:Handle
  in
  let text =
    residual ~arms:[ arm ] input
    |> generated ~catalogues:[ catalogue ]
    |> print_cases
  in
  Alcotest.(check int)
    "one dispatch" 1
    (count_occurrences text "Cases.dispatch");
  Alcotest.(check int)
    "one propagate" 1
    (count_occurrences text "Cases.propagate");
  Alcotest.(check bool)
    "handled field overridden" true
    (contains text "Cases.first_error")

let test_cases_full_exhaustion_and_no_duplicate_arms () =
  let catalogue, first, second, third = cases_fixture () in
  let input = proof Kind.Error [ first; second; third ] in
  let arms =
    List.map
      (fun leaf ->
        Residual.arm
          ~target:(Complete_leaf (Leaf.identity leaf))
          ~guard:Unguarded ~action:Handle)
      [ first; second; third ]
  in
  let cases = residual ~arms input |> generated ~catalogues:[ catalogue ] in
  Alcotest.(check int) "refutation plus warning case" 2 (List.length cases);
  cases |> List.hd |> check_refutation_case "exhaustion guard";
  let text = print_cases cases in
  Alcotest.(check int)
    "no residual dispatch" 0
    (count_occurrences text "Cases.dispatch");
  Alcotest.(check int)
    "one warning case" 1
    (count_occurrences text "assert false")

let test_cases_subset_uses_direct_leaf () =
  let catalogue, first, _, _ = cases_fixture () in
  let text =
    residual (proof Kind.Error [ first ])
    |> generated ~catalogues:[ catalogue ]
    |> print_cases
  in
  Alcotest.(check bool)
    "direct named leaf" true
    (contains text "#Service.Errors.first_error");
  Alcotest.(check bool)
    "no cases widening" false
    (contains text "Cases.dispatch")

let span =
  Source_span.make ~file:"engine_test.ml" ~start_offset:0 ~end_offset:1
    ~start_line:1 ~start_column:0 ~end_line:1 ~end_column:1
  |> get_ok "span"

let marker value kind =
  let id = Marker.id_of_string value |> get_ok "marker id" in
  Marker.make ~id ~kind ~span

let test_resolver_catalogue_expansion_parity () =
  let catalogue, first, second, third = cases_fixture () in
  let input = proof Kind.Error [ first; second; third ] in
  let arm =
    Residual.arm
      ~target:(Complete_leaf (Leaf.identity first))
      ~guard:Unguarded ~action:Handle
  in
  let calculation = residual ~arms:[ arm ] input in
  let in_process =
    generated ~catalogues:[ catalogue ] calculation |> print_cases
  in
  let marker = marker "e:catalogue-parity" Kind.Error in
  let certificate = (resolved_value calculation).certificate in
  let result =
    Protocol.marker_result ~marker ~outcome:(Protocol.Resolved calculation)
      ~certificate:(Some certificate)
    |> get_ok "parity marker result"
  in
  let response =
    Protocol.response
      ~catalogues:[ Hamlet_subtractor_catalogue.to_protocol catalogue ]
      ~request_id:"parity-request" ~context_fingerprint:"parity-context"
      ~ast_digest:"parity-ast" [ result ]
    |> get_ok "parity response"
    |> Protocol.encode
    |> Protocol.decode
    |> get_ok "parity decode"
  in
  let resolver_catalogues =
    Protocol.catalogues response
    |> List.map Hamlet_subtractor_catalogue.of_protocol
  in
  let resolver_calculation =
    match Protocol.results response with
    | [ result ] -> (
        match Protocol.outcome result with
        | Protocol.Resolved calculation -> calculation
        | Protocol.Refused _ -> Alcotest.fail "parity result was refused")
    | _ -> Alcotest.fail "expected one parity result"
  in
  let via_resolver =
    generated ~catalogues:resolver_catalogues resolver_calculation
    |> print_cases
  in
  Alcotest.(check string) "full Cases expansion parity" in_process via_resolver;
  Alcotest.(check int)
    "resolver keeps one linear dispatch" 1
    (count_occurrences via_resolver "Cases.dispatch")

let parse source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf "replace_test.ml";
  Parse.implementation lexbuf

let owner_source ?(user_attribute = false) id =
  let user_attribute = if user_attribute then "[@tailcall]" else "" in
  Printf.sprintf
    "let value =\n\
     ((consume\n\
     (match (input [@hamlet.subtractor.upstream.v1 %S]) with\n\
     | _ ->\n\
     (assert false [@hamlet.subtractor.marker.v1 %S])))\n\
     %s\n\
     [@hamlet.subtractor.owner.v1 %S])"
    id id user_attribute id

let replace_resolved
    ?(catalogues = [])
    marker
    (resolved : Hamlet_subtractor_engine.resolved)
    source =
  parse source
  |> Hamlet_subtractor_replace.structure ~catalogues
       ~outcomes:[ (marker, Protocol.Resolved resolved.residual) ]
       ~resolved_values:[ (marker, resolved) ]

let constraints structure =
  let constraints = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        begin match expression.pexp_desc with
        | Pexp_constraint (inner, type_) ->
            constraints := (expression, inner, type_) :: !constraints
        | _ -> ()
        end;
        super#expression expression
    end
  in
  iterator#structure structure;
  List.rev !constraints

let only_owner_constraint structure =
  match
    constraints structure
    |> List.filter (fun (_, inner, _) ->
        match inner.pexp_desc with Pexp_apply _ -> true | _ -> false)
  with
  | [ constraint_ ] -> constraint_
  | _ -> Alcotest.fail "expected one owner result constraint"

let exact_row_fields label type_ =
  match type_.ptyp_desc with
  | Ptyp_variant (fields, Closed, None) -> fields
  | _ -> Alcotest.fail (label ^ " is not an exact closed row")

let inherited_names fields =
  List.filter_map
    (fun field ->
      match field.prf_desc with
      | Rinherit { ptyp_desc = Ptyp_constr ({ txt; _ }, []); _ } ->
          Some (Longident.flatten_exn txt |> String.concat ".")
      | Rinherit _ | Rtag _ -> None)
    fields

let hamlet_effect_channels type_ =
  match type_.ptyp_desc with
  | Ptyp_constr
      ( { txt = Ldot (Lident "Hamlet", "t"); _ },
        [ { ptyp_desc = Ptyp_any; _ }; errors; requirements ] ) ->
      (errors, requirements)
  | _ -> Alcotest.fail "owner constraint is not an (_, _, _) Hamlet.t"

let is_hamlet_never type_ =
  match type_.ptyp_desc with
  | Ptyp_constr ({ txt = Ldot (Lident "Hamlet", "never"); _ }, []) -> true
  | _ -> false

let test_certificate_type_materialization () =
  let marker = marker "e:certificate-types" Kind.Error in
  let direct = error_leaf "materialized_direct" "Materialized_direct" in
  let catalogue, cases, _, _ = cases_fixture () in
  let nominal_declaration = identity ~module_path:[ "Payload" ] "box" in
  let nominal_payload =
    Type_identity.nominal ~declaration:nominal_declaration
      ~arguments:[ Type_identity.primitive String ]
  in
  let tuple_payload =
    Type_identity.tuple [ Type_identity.primitive Int; nominal_payload ]
    |> get_ok "tuple payload"
  in
  let structural_identity =
    identity ~module_path:[ "Inline" ] "structural_payload"
  in
  let structural_atom =
    atom structural_identity "Structural_payload" (Atom.Payload tuple_payload)
  in
  let structural =
    Leaf.error ~identity:structural_identity ~members:[ structural_atom ]
      ~materialization:Leaf.Structural_variant
    |> get_ok "structural payload leaf"
  in
  let errors = proof Kind.Error [ direct; cases; structural ] in
  let requirements =
    proof Kind.Requirement [ requirement_leaf "Logger" "Logger" ]
  in
  let calculation = residual errors in
  let certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact errors)
      ~requirements:(Effect_certificate.exact requirements)
    |> get_ok "materialized certificate"
  in
  let resolved =
    Hamlet_subtractor_engine.{ residual = calculation; certificate }
  in
  let output =
    owner_source ~user_attribute:true "e:certificate-types"
    |> replace_resolved ~catalogues:[ catalogue ] marker resolved
    |> get_ok "certificate replacement"
  in
  let wrapper, inner, type_ = only_owner_constraint output in
  Alcotest.(check int)
    "constraint wrapper has no attrs" 0
    (List.length wrapper.pexp_attributes);
  Alcotest.(check bool)
    "original call remains an application" true
    (match inner.pexp_desc with Pexp_apply _ -> true | _ -> false);
  Alcotest.(check int)
    "application keeps one user attr" 1
    (List.length inner.pexp_attributes);
  Alcotest.(check string)
    "application attr name" "tailcall"
    (List.hd inner.pexp_attributes).attr_name.txt;
  let errors, requirements = hamlet_effect_channels type_ in
  let error_fields = exact_row_fields "error certificate" errors in
  let inherited = inherited_names error_fields |> List.sort String.compare in
  Alcotest.(check (list string))
    "named and Cases leaves use Rinherit"
    [ "Service.Errors.first_error"; "Service.Errors.materialized_direct" ]
    inherited;
  let structural_field =
    List.find_opt
      (fun field ->
        match field.prf_desc with
        | Rtag ({ txt = "Structural_payload"; _ }, _, _) -> true
        | _ -> false)
      error_fields
  in
  (match structural_field with
  | Some
      {
        prf_desc =
          Rtag
            ( _,
              false,
              [
                {
                  ptyp_desc =
                    Ptyp_tuple
                      [
                        {
                          ptyp_desc = Ptyp_constr ({ txt = Lident "int"; _ }, []);
                          _;
                        };
                        {
                          ptyp_desc =
                            Ptyp_constr
                              ( { txt = Ldot (Lident "Payload", "box"); _ },
                                [
                                  {
                                    ptyp_desc =
                                      Ptyp_constr
                                        ({ txt = Lident "string"; _ }, []);
                                    _;
                                  };
                                ] );
                          _;
                        };
                      ];
                  _;
                };
              ] );
        _;
      } ->
      ()
  | _ -> Alcotest.fail "structural tuple and nominal payload changed shape");
  let requirement_fields =
    exact_row_fields "requirement certificate" requirements
  in
  Alcotest.(check (list string))
    "requirement tag uses Rinherit" [ "Logger.Tag.r" ]
    (inherited_names requirement_fields);
  Alcotest.(check bool)
    "generated certificate type is ghost" true type_.ptyp_loc.loc_ghost

let test_upstream_certificate_materialization () =
  let marker = marker "s:upstream-certificate" Kind.Requirement in
  let logger = requirement_leaf "Logger" "Logger" in
  let clock = requirement_leaf "Clock" "Clock" in
  let input = proof Kind.Requirement [ logger; clock ] in
  let logger_arm =
    Residual.arm
      ~target:(Complete_leaf (Leaf.identity logger))
      ~guard:Unguarded ~action:Handle
  in
  let calculation = residual ~arms:[ logger_arm ] input in
  let certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact (empty_proof Kind.Error))
      ~requirements:
        (Effect_certificate.exact
           (proof Kind.Requirement (Residual.output calculation)))
    |> get_ok "upstream certificate"
  in
  let resolved =
    Hamlet_subtractor_engine.{ residual = calculation; certificate }
  in
  let source =
    "let result =\n\
     ((consume\n\
     (input [@hamlet.subtractor.upstream.v1 \"s:upstream-certificate\"])\n\
     (match requirement with\n\
     | _ -> (assert false [@hamlet.subtractor.marker.v1 \
     \"s:upstream-certificate\"])))\n\
     [@hamlet.subtractor.owner.v1 \"s:upstream-certificate\"])"
  in
  let output =
    source
    |> replace_resolved marker resolved
    |> get_ok "upstream certificate replacement"
  in
  let types = constraints output |> List.map (fun (_, _, type_) -> type_) in
  Alcotest.(check int) "owner and upstream constraints" 2 (List.length types);
  let requirement_rows =
    List.map hamlet_effect_channels types
    |> List.map snd
    |> List.map (exact_row_fields "requirement certificate")
    |> List.map inherited_names
    |> List.sort_uniq (List.compare String.compare)
  in
  Alcotest.(check (list (list string)))
    "upstream is closed to the exact source row"
    [ [ "Clock.Tag.r" ]; [ "Clock.Tag.r"; "Logger.Tag.r" ] ]
    requirement_rows

let test_empty_and_opaque_certificate_materialization () =
  let empty_marker = marker "e:certificate-empty" Kind.Error in
  let empty_errors = empty_proof Kind.Error in
  let empty_requirements = empty_proof Kind.Requirement in
  let empty_result = residual empty_errors in
  let empty_certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact empty_errors)
      ~requirements:(Effect_certificate.exact empty_requirements)
    |> get_ok "empty certificate"
  in
  let empty_resolved =
    Hamlet_subtractor_engine.
      { residual = empty_result; certificate = empty_certificate }
  in
  let _, _, empty_type =
    owner_source "e:certificate-empty"
    |> replace_resolved empty_marker empty_resolved
    |> get_ok "empty certificate replacement"
    |> only_owner_constraint
  in
  let errors, requirements = hamlet_effect_channels empty_type in
  Alcotest.(check bool)
    "empty errors become Hamlet.never" true (is_hamlet_never errors);
  Alcotest.(check bool)
    "empty requirements become Hamlet.never" true
    (is_hamlet_never requirements);
  let opaque_marker = marker "e:certificate-opaque" Kind.Error in
  let error = error_leaf "opaque_error" "Opaque_error" in
  let opaque_errors = proof Kind.Error [ error ] in
  let opaque_result = residual opaque_errors in
  let opaque_certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact opaque_errors)
      ~requirements:(Effect_certificate.opaque Unproven_origin)
    |> get_ok "opaque opposite certificate"
  in
  let opaque_resolved =
    Hamlet_subtractor_engine.
      { residual = opaque_result; certificate = opaque_certificate }
  in
  let _, _, opaque_type =
    owner_source "e:certificate-opaque"
    |> replace_resolved opaque_marker opaque_resolved
    |> get_ok "opaque certificate replacement"
    |> only_owner_constraint
  in
  let errors, requirements = hamlet_effect_channels opaque_type in
  ignore (exact_row_fields "exact target channel" errors);
  Alcotest.(check bool)
    "opaque opposite channel uses underscore" true
    (match requirements.ptyp_desc with Ptyp_any -> true | _ -> false)

let test_exact_unavailable_certificate_is_rejected () =
  let marker = marker "e:certificate-unavailable" Kind.Error in
  let error = error_leaf "available_error" "Available_error" in
  let errors = proof Kind.Error [ error ] in
  let result = residual errors in
  let unavailable_identity = identity ~module_path:[ "Hidden"; "Tag" ] "r" in
  let unavailable_atom =
    atom ~kind:Kind.Requirement unavailable_identity "Hidden" Atom.No_payload
  in
  let unavailable =
    Leaf.requirement ~identity:unavailable_identity ~member:unavailable_atom
      ~materialization:(Leaf.Unavailable Leaf.No_named_pattern)
    |> get_ok "unavailable requirement"
  in
  let requirements = proof Kind.Requirement [ unavailable ] in
  let certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact errors)
      ~requirements:(Effect_certificate.exact requirements)
    |> get_ok "unavailable certificate"
  in
  let resolved = Hamlet_subtractor_engine.{ residual = result; certificate } in
  match
    owner_source "e:certificate-unavailable" |> replace_resolved marker resolved
  with
  | Error (Hamlet_subtractor_replace.Unmaterializable_certificate (_, leaf))
    when Leaf.equal leaf unavailable ->
      ()
  | _ -> Alcotest.fail "exact unavailable evidence was weakened to underscore"

let test_replacement_preserves_user_cases_and_strips_probe_attributes () =
  let marker = marker "e:replace" Kind.Error in
  let leaf = error_leaf "replacement_error" "Replacement" in
  let result = residual (proof Kind.Error [ leaf ]) in
  let source =
    "let handle value =\n\
     ((match (value [@hamlet.subtractor.upstream.v1 \"e:replace\"]) with\n\
     | `Handled -> assert false\n\
     | _ ->\n\
     ((assert false)\n\
     [@hamlet.subtractor.marker.v1 \"e:replace\"]\n\
     [@hamlet.subtractor.callee.v1 \"e:replace\"]\n\
     [@hamlet.subtractor.handler.v1 \"e:replace\"]))\n\
     [@hamlet.subtractor.owner.v1 \"e:replace\"])"
  in
  let resolved = resolved_value result in
  let output =
    parse source
    |> Hamlet_subtractor_replace.structure ~catalogues:[]
         ~outcomes:[ (marker, Protocol.Resolved result) ]
         ~resolved_values:[ (marker, resolved) ]
    |> get_ok "replacement"
  in
  let probe_attributes = ref [] in
  let matches = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! attribute attribute =
        if
          String.starts_with ~prefix:"hamlet.subtractor."
            attribute.attr_name.txt
        then probe_attributes := attribute.attr_name.txt :: !probe_attributes;
        super#attribute attribute

      method! expression expression =
        begin match expression.pexp_desc with
        | Pexp_match (_, cases) -> matches := cases :: !matches
        | _ -> ()
        end;
        super#expression expression
    end
  in
  iterator#structure output;
  Alcotest.(check (list string)) "no probe attrs" [] !probe_attributes;
  match !matches with
  | [ first :: _ ] -> (
      match first.pc_lhs.ppat_desc with
      | Ppat_variant ("Handled", None) -> ()
      | _ -> Alcotest.fail "preceding user case changed")
  | _ -> Alcotest.fail "expected one rewritten match"

let test_replacement_requires_exactly_one_owner () =
  let marker = marker "e:owner-count" Kind.Error in
  let leaf = error_leaf "owner_error" "Owner_error" in
  let result = residual (proof Kind.Error [ leaf ]) in
  let resolved = resolved_value result in
  let replace source =
    parse source
    |> Hamlet_subtractor_replace.structure ~catalogues:[]
         ~outcomes:[ (marker, Protocol.Resolved result) ]
         ~resolved_values:[ (marker, resolved) ]
  in
  let marker_case =
    "match value with\n\
     | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:owner-count\"])"
  in
  (match replace ("let handle value = " ^ marker_case) with
  | Error (Hamlet_subtractor_replace.Missing_owner id)
    when Marker.compare_id id (Marker.id marker) = 0 ->
      ()
  | _ -> Alcotest.fail "missing owner was not rejected");
  let duplicate =
    Printf.sprintf
      "let handle value =\n\
       ((%s)\n\
       [@hamlet.subtractor.owner.v1 \"e:owner-count\"]\n\
       [@hamlet.subtractor.owner.v1 \"e:owner-count\"])"
      marker_case
  in
  match replace duplicate with
  | Error (Hamlet_subtractor_replace.Duplicate_owner id)
    when Marker.compare_id id (Marker.id marker) = 0 ->
      ()
  | _ -> Alcotest.fail "duplicate owner was not rejected"

let test_replacement_requires_exactly_one_upstream () =
  let marker = marker "e:upstream-count" Kind.Error in
  let leaf = error_leaf "upstream_error" "Upstream_error" in
  let result = residual (proof Kind.Error [ leaf ]) in
  let resolved = resolved_value result in
  let replace source =
    parse source
    |> Hamlet_subtractor_replace.structure ~catalogues:[]
         ~outcomes:[ (marker, Protocol.Resolved result) ]
         ~resolved_values:[ (marker, resolved) ]
  in
  let marker_case =
    "match value with\n\
     | _ -> (assert false [@hamlet.subtractor.marker.v1 \"e:upstream-count\"])"
  in
  let missing =
    Printf.sprintf
      "let handle value =\n\
       ((%s)\n\
       [@hamlet.subtractor.owner.v1 \"e:upstream-count\"])"
      marker_case
  in
  (match replace missing with
  | Error (Hamlet_subtractor_replace.Missing_upstream id)
    when Marker.compare_id id (Marker.id marker) = 0 ->
      ()
  | _ -> Alcotest.fail "missing upstream was not rejected");
  let duplicate =
    Printf.sprintf
      "let handle value =\n\
       ((match\n\
       (value [@hamlet.subtractor.upstream.v1 \"e:upstream-count\"])\n\
       with\n\
       | _ -> (assert false [@hamlet.subtractor.marker.v1 \
       \"e:upstream-count\"]))\n\
       [@hamlet.subtractor.upstream.v1 \"e:upstream-count\"]\n\
       [@hamlet.subtractor.owner.v1 \"e:upstream-count\"])"
  in
  match replace duplicate with
  | Error (Hamlet_subtractor_replace.Duplicate_upstream id)
    when Marker.compare_id id (Marker.id marker) = 0 ->
      ()
  | _ -> Alcotest.fail "duplicate upstream was not rejected"

let resolver_request marker =
  let tool_context =
    Protocol.
      {
        ocaml_version = "5.5.0";
        hamlet_subtractor_version = "test";
        resolver_version = "test";
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
  let probe_ast =
    Protocol.
      {
        path = "/tmp/resolver-test.ast";
        input_name = "resolver_test.ml";
        magic = "Caml1999M999";
        digest = "resolver-ast";
        byte_length = 32;
      }
  in
  Protocol.request ~request_id:"resolver-request"
    ~source_file:"resolver_test.ml" ~tool_name:"ocamlopt" ~probe_ast
    ~probe_unit:(Protocol.Synthetic_unit "Hamlet_subtractor_probe_test")
    ~tool_context ~context_fingerprint:"context" ~include_dirs:[]
    ~hidden_include_dirs:[] ~visible_paths:[] ~hidden_paths:[] ~opens:[]
    ~package_mode:Standalone ~compiler_flags ~expected_markers:[ marker ]
  |> get_ok "resolver request"

let test_resolver_protocol_framing_and_correlation () =
  let marker = marker "e:resolver" Kind.Error in
  let result =
    residual (proof Kind.Error [ error_leaf "resolver_error" "Resolver" ])
  in
  let request = resolver_request marker in
  let certificate = (resolved_value result).certificate in
  let resolve request =
    let marker_result =
      Protocol.marker_result ~marker ~outcome:(Protocol.Resolved result)
        ~certificate:(Some certificate)
      |> get_ok "marker result"
    in
    Protocol.response
      ~request_id:(Protocol.request_id request)
      ~context_fingerprint:(Protocol.request_context_fingerprint request)
      ~ast_digest:(Protocol.probe_ast request).digest [ marker_result ]
    |> get_ok "response"
    |> fun response -> Ok response
  in
  let framed =
    Protocol.encode_request request
    |> Hamlet_subtractor_resolver_protocol.encode_frame
  in
  let output =
    Hamlet_subtractor_resolver_protocol.handle ~max_request:4096
      ~max_response:4096 ~resolve framed
    |> get_ok "resolver frame"
  in
  Hamlet_subtractor_resolver_protocol.decode_frame ~max_payload:4096 output
  |> get_ok "response frame"
  |> ignore;
  let expect_error label input =
    match
      Hamlet_subtractor_resolver_protocol.handle ~max_request:4096
        ~max_response:4096 ~resolve input
    with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (label ^ " unexpectedly succeeded")
  in
  expect_error "missing header" (Protocol.encode_request request);
  expect_error "trailing frame" (framed ^ framed);
  expect_error "malformed JSON"
    (Hamlet_subtractor_resolver_protocol.encode_frame "{not-json}");
  let wrong_context _request =
    let marker_result =
      Protocol.marker_result ~marker ~outcome:(Protocol.Resolved result)
        ~certificate:(Some certificate)
      |> get_ok "wrong marker result"
    in
    Protocol.response
      ~request_id:(Protocol.request_id request)
      ~context_fingerprint:"wrong"
      ~ast_digest:(Protocol.probe_ast request).digest [ marker_result ]
    |> get_ok "wrong response"
    |> fun response -> Ok response
  in
  match
    Hamlet_subtractor_resolver_protocol.handle ~max_request:4096
      ~max_response:4096 ~resolve:wrong_context framed
  with
  | Error
      (Hamlet_subtractor_resolver_protocol.Correlation
         (Protocol.Context_fingerprint_mismatch _)) ->
      ()
  | Error error ->
      Alcotest.fail
        ("unexpected correlation error: "
        ^ Hamlet_subtractor_resolver_protocol.message error)
  | Ok _ -> Alcotest.fail "wrong context unexpectedly correlated"

let test_engine_dependency_order_and_cycle () =
  let first = marker "e:first" Kind.Error in
  let second = marker "e:second" Kind.Error in
  let leaf = error_leaf "engine_error" "Engine" in
  let result = residual (proof Kind.Error [ leaf ]) in
  let calls = ref [] in
  let backend =
    Hamlet_subtractor_engine.
      {
        dependencies =
          (fun () current ->
            if Marker.equal current second then Ok [ Marker.id first ]
            else Ok []);
        resolve =
          (fun () ~marker ~dependencies:_ ->
            calls := Marker.id_to_string (Marker.id marker) :: !calls;
            Ok (resolved_value result));
      }
  in
  Hamlet_subtractor_engine.elaborate ~backend ~context:() ~catalogues:[]
    ~markers:[ second; first ]
  |> get_ok "engine"
  |> ignore;
  Alcotest.(check (list string))
    "stable ready order" [ "e:first"; "e:second" ] (List.rev !calls);
  let cycle_backend =
    Hamlet_subtractor_engine.
      {
        dependencies =
          (fun () current ->
            if Marker.equal current first then Ok [ Marker.id second ]
            else Ok [ Marker.id first ]);
        resolve =
          (fun () ~marker:_ ~dependencies:_ -> Ok (resolved_value result));
      }
  in
  let cycle =
    Hamlet_subtractor_engine.elaborate ~backend:cycle_backend ~context:()
      ~catalogues:[] ~markers:[ first; second ]
    |> get_ok "cycle"
  in
  Hamlet_subtractor_engine.outcomes cycle
  |> List.iter (function
    | _, Protocol.Refused diagnostic -> (
        match Diagnostic.code diagnostic with
        | Recursive_dependency ids ->
            Alcotest.(check int) "two cycle members" 2 (List.length ids)
        | _ -> Alcotest.fail "expected recursive dependency")
    | _, Protocol.Resolved _ -> Alcotest.fail "cycle unexpectedly resolved")

let exact_leaf_count evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Exact_proof proof -> List.length (Proof.leaves proof)
  | Effect_certificate.Opaque_reasons _ -> Alcotest.fail "opaque dependency"

let test_engine_accepts_exact_certificate_contributors () =
  let marker = marker "s:provider" Kind.Requirement in
  let contributed = requirement_leaf "Clock" "Clock" in
  let result =
    Residual.calculate
      ~input:(empty_proof Kind.Requirement)
      ~arms:[] ~recovery:[ contributed ]
    |> get_ok "contributor residual"
  in
  let certificate =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact (empty_proof Kind.Error))
      ~requirements:
        (Effect_certificate.exact (proof Kind.Requirement [ contributed ]))
    |> get_ok "contributor certificate"
  in
  let backend =
    Hamlet_subtractor_engine.
      {
        dependencies = (fun () _ -> Ok []);
        resolve =
          (fun () ~marker:_ ~dependencies:_ ->
            Ok { residual = result; certificate });
      }
  in
  let engine =
    Hamlet_subtractor_engine.elaborate ~backend ~context:() ~catalogues:[]
      ~markers:[ marker ]
    |> get_ok "contributor engine"
  in
  match Hamlet_subtractor_engine.outcomes engine with
  | [ (_, Protocol.Resolved _) ] -> ()
  | [ (_, Protocol.Refused _) ] ->
      Alcotest.fail "exact certificate contributor was refused"
  | _ -> Alcotest.fail "unexpected contributor outcome count"

let test_interleaved_channels_keep_certificates () =
  let error_marker = marker "e:catch" Kind.Error in
  let requirement_marker = marker "s:provide" Kind.Requirement in
  let error_leaf = error_leaf "interleaved_error" "Interleaved_error" in
  let requirement_leaf = requirement_leaf "Clock" "Clock" in
  let error_residual = residual (proof Kind.Error [ error_leaf ]) in
  let requirement_residual =
    residual (proof Kind.Requirement [ requirement_leaf ])
  in
  let combined_certificate () =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact (proof Kind.Error [ error_leaf ]))
      ~requirements:
        (Effect_certificate.exact (proof Kind.Requirement [ requirement_leaf ]))
    |> get_ok "combined certificate"
  in
  let run ~first ~second ~first_residual ~second_residual ~inspect =
    let backend =
      Hamlet_subtractor_engine.
        {
          dependencies =
            (fun () current ->
              if Marker.equal current second then Ok [ Marker.id first ]
              else Ok []);
          resolve =
            (fun () ~marker ~dependencies ->
              if Marker.equal marker first then
                Ok
                  {
                    residual = first_residual;
                    certificate = combined_certificate ();
                  }
              else
                match dependencies with
                | [ (_, dependency) ] ->
                    inspect dependency.certificate;
                    Ok
                      {
                        residual = second_residual;
                        certificate = combined_certificate ();
                      }
                | _ -> Alcotest.fail "missing interleaved dependency");
        }
    in
    Hamlet_subtractor_engine.elaborate ~backend ~context:() ~catalogues:[]
      ~markers:[ second; first ]
    |> get_ok "interleaved engine"
    |> ignore
  in
  run ~first:error_marker ~second:requirement_marker
    ~first_residual:error_residual ~second_residual:requirement_residual
    ~inspect:(fun certificate ->
      Alcotest.(check int)
        "catch keeps requirements" 1
        (exact_leaf_count (Effect_certificate.requirements certificate)));
  run ~first:requirement_marker ~second:error_marker
    ~first_residual:requirement_residual ~second_residual:error_residual
    ~inspect:(fun certificate ->
      Alcotest.(check int)
        "provide keeps errors" 1
        (exact_leaf_count (Effect_certificate.errors certificate)))

let count_identifier name expression =
  let count = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        (match expression.pexp_desc with
        | Pexp_ident { txt = Lident actual; _ } when String.equal name actual ->
            incr count
        | _ -> ());
        super#expression expression
    end
  in
  iterator#expression expression;
  !count

let test_generic_slot_routes_complete_input () =
  let missing =
    error_leaf ~materialization:Leaf.Structural_variant "missing" "Missing"
  in
  let timeout =
    error_leaf ~materialization:Leaf.Structural_variant "timeout" "Timeout"
  in
  let slot =
    Hamlet_subtractor_generic_generator.slot ~loc:Location.none ~catalogues:[]
      ~input:(proof Kind.Error [ missing; timeout ])
      ~claimed:[ missing ]
    |> get_ok "generic slot"
  in
  Alcotest.(check int)
    "one handled callback" 1
    (count_identifier "handled" slot);
  Alcotest.(check int)
    "one forwarding callback" 1
    (count_identifier "forward" slot);
  let matches = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        (match expression.pexp_desc with
        | Pexp_match (_, cases) -> matches := List.length cases :: !matches
        | _ -> ());
        super#expression expression
    end
  in
  iterator#expression slot;
  Alcotest.(check (list int)) "two leaves and an invariant guard" [ 3 ] !matches

let test_generic_slot_uses_catalogue_dispatch () =
  let catalogue, first, second, third = cases_fixture () in
  let slot =
    Hamlet_subtractor_generic_generator.slot ~loc:Location.none
      ~catalogues:[ catalogue ]
      ~input:(proof Kind.Error [ first; second; third ])
      ~claimed:[ first; third ]
    |> get_ok "catalogue generic slot"
  in
  let rendered =
    let structure =
      [ Ast_builder.Default.pstr_eval ~loc:Location.none slot [] ]
    in
    let structure =
      Selected_ast.to_ocaml Selected_ast.Type.Structure structure
    in
    Format.asprintf "%a" Compiler_pprintast.structure structure
  in
  Alcotest.(check int)
    "one catalogue dispatch" 1
    (count_occurrences rendered "Cases.dispatch");
  Alcotest.(check int)
    "two handled catalogue fields" 2
    (count_identifier "handled" slot);
  Alcotest.(check int)
    "one forwarded catalogue field" 1
    (count_identifier "forward" slot)

let test_generic_bundle_abi () =
  let first = Ast_builder.Default.eint ~loc:Location.none 1 in
  let second = Ast_builder.Default.eint ~loc:Location.none 2 in
  let single =
    Hamlet_subtractor_generic_generator.bundle ~loc:Location.none [ first ]
  in
  let multiple =
    Hamlet_subtractor_generic_generator.bundle ~loc:Location.none
      [ first; second ]
  in
  begin match single.pexp_desc with
  | Pexp_constant _ -> ()
  | _ -> Alcotest.fail "one generic slot must stay bare"
  end;
  begin match multiple.pexp_desc with
  | Pexp_tuple [ _; _ ] -> ()
  | _ -> Alcotest.fail "multiple generic slots must use one tuple argument"
  end

let () =
  Alcotest.run "hamlet elaboration engine"
    [
      ( "generation",
        [
          Alcotest.test_case "error and requirement forwarding" `Quick
            test_error_and_requirement_generation;
          Alcotest.test_case "Layer.fail_like forwarding" `Quick
            test_layer_fail_like_generation;
          Alcotest.test_case "nonempty refutation guard" `Quick
            test_nonempty_generation_appends_refutation_guard;
          Alcotest.test_case "structural arity" `Quick test_structural_arity;
          Alcotest.test_case "linear cases dispatch" `Quick
            test_cases_is_one_linear_dispatch;
          Alcotest.test_case "full cases exhaustion" `Quick
            test_cases_full_exhaustion_and_no_duplicate_arms;
          Alcotest.test_case "cases subset stays direct" `Quick
            test_cases_subset_uses_direct_leaf;
          Alcotest.test_case "resolver Cases parity" `Quick
            test_resolver_catalogue_expansion_parity;
          Alcotest.test_case "generated location ownership" `Quick
            test_generated_locations_keep_only_outer_marker_real;
          Alcotest.test_case "replacement preserves user cases" `Quick
            test_replacement_preserves_user_cases_and_strips_probe_attributes;
          Alcotest.test_case "replacement owner is exact" `Quick
            test_replacement_requires_exactly_one_owner;
          Alcotest.test_case "replacement upstream is exact" `Quick
            test_replacement_requires_exactly_one_upstream;
          Alcotest.test_case "certificate type materialization" `Quick
            test_certificate_type_materialization;
          Alcotest.test_case "upstream certificate materialization" `Quick
            test_upstream_certificate_materialization;
          Alcotest.test_case "empty and opaque certificate types" `Quick
            test_empty_and_opaque_certificate_materialization;
          Alcotest.test_case "unavailable certificate is rejected" `Quick
            test_exact_unavailable_certificate_is_rejected;
          Alcotest.test_case "generic slot routes complete input" `Quick
            test_generic_slot_routes_complete_input;
          Alcotest.test_case "generic slot uses Cases dispatch" `Quick
            test_generic_slot_uses_catalogue_dispatch;
          Alcotest.test_case "generic bundle ABI" `Quick test_generic_bundle_abi;
        ] );
      ( "fixpoint",
        [
          Alcotest.test_case "dependency order and cycle" `Quick
            test_engine_dependency_order_and_cycle;
          Alcotest.test_case "interleaved channels keep certificates" `Quick
            test_interleaved_channels_keep_certificates;
          Alcotest.test_case "exact certificate contributors" `Quick
            test_engine_accepts_exact_certificate_contributors;
        ] );
      ( "resolver",
        [
          Alcotest.test_case "strict framing and correlation" `Quick
            test_resolver_protocol_framing_and_correlation;
        ] );
    ]
