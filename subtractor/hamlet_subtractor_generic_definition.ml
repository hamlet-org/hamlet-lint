open Ppxlib
module A = Ast_builder.Default
module Contract = Hamlet_subtractor_generic_contract
module Descriptor = Hamlet_subtractor_core.Owner_descriptor

let generic_attribute = "hamlet.generic"
let marker_attribute = "hamlet.subtractor.marker.v1"
let helper_attribute = "hamlet.subtractor.generic_helper.v1"
let owner_attribute = "hamlet.subtractor.generic_owner.v1"
let callee_attribute = "hamlet.subtractor.generic_callee.v1"
let upstream_attribute = "hamlet.subtractor.generic_upstream.v1"
let handler_attribute = "hamlet.subtractor.generic_handler.v1"
let slot_attribute = "hamlet.subtractor.generic_slot.v1"
let nested_call_attribute = "hamlet.subtractor.generic_nested_call.v1"
let nested_callee_attribute = "hamlet.subtractor.generic_nested_callee.v1"
let nested_source_attribute = "hamlet.subtractor.generic_nested_source.v1"
let nested_specialized_attribute =
  "hamlet.subtractor.generic_nested_specialized.v2"

type refusal_reason =
  | Invalid_annotation_payload
  | Duplicate_annotation
  | Recursive_binding
  | Anonymous_binding
  | Not_a_function
  | Missing_source_parameter
  | Unsupported_source_parameter
  | No_automatic_markers
  | Source_not_linear of int
  | Unsupported_source_flow
  | Marker_without_supported_owner
  | Wrong_marker_channel
  | Unsupported_handler
  | Multiple_symbolic_inputs of string list
  | Invalid_nested_call of string
  | Duplicate_helper of string
  | Companion_collision of string
  | Contract_encoding_failed of string

type refusal = { loc : Location.t; reason : refusal_reason }

exception Refusal of refusal

let refusal_message = function
  | Invalid_annotation_payload -> "[@hamlet.generic] does not accept a payload"
  | Duplicate_annotation ->
      "the binding has more than one [@hamlet.generic] annotation"
  | Recursive_binding ->
      "[@hamlet.generic] supports only non-recursive functions"
  | Anonymous_binding ->
      "[@hamlet.generic] requires a simple named value binding"
  | Not_a_function -> "[@hamlet.generic] requires a directly written function"
  | Missing_source_parameter ->
      "the generic helper has no positional effect parameter"
  | Unsupported_source_parameter ->
      "the final helper parameter must be an unlabelled variable containing \
       the generic Hamlet computation"
  | No_automatic_markers ->
      "the generic helper contains no automatic propagation marker"
  | Source_not_linear count ->
      Printf.sprintf
        "the generic effect parameter must occur exactly once in the helper \
         body; found %d occurrences"
        count
  | Unsupported_source_flow ->
      "the generic effect parameter must flow directly through supported \
       Hamlet combinators to every automatic marker"
  | Marker_without_supported_owner ->
      "a generic automatic marker is not owned by a direct or piped \
       Hamlet.Combinators.catch/provide call with an inline handler"
  | Wrong_marker_channel ->
      "the generic automatic marker channel does not match its catch/provide \
       owner"
  | Unsupported_handler ->
      "a generic automatic marker requires an inline function handler with one \
       final marker arm"
  | Multiple_symbolic_inputs names ->
      Printf.sprintf
        "the generic source flow contains another helper parameter (%s); \
         version one supports one symbolic effect input"
        (String.concat ", " names)
  | Invalid_nested_call message ->
      "a nested generic-helper call is invalid: " ^ message
  | Duplicate_helper name ->
      Printf.sprintf
        "generic helper %s is declared more than once in this compilation unit"
        name
  | Companion_collision name ->
      Printf.sprintf
        "generated generic-helper companion module %s collides with an \
         existing module"
        name
  | Contract_encoding_failed message ->
      "cannot encode the provisional generic-helper contract: " ^ message

let refuse ~loc reason = raise (Refusal { loc; reason })

let string_payload = function
  | PStr
      [
        {
          pstr_desc =
            Pstr_eval
              ({ pexp_desc = Pexp_constant (Pconst_string (value, _, _)); _ }, _);
          _;
        };
      ] ->
      Some value
  | _ -> None

let marker_ids attributes =
  List.filter_map
    (fun attribute ->
      if String.equal attribute.attr_name.txt marker_attribute then
        string_payload attribute.attr_payload
      else None)
    attributes

let marker_kind id =
  if String.starts_with ~prefix:"e:" id then Some Contract.Error
  else if String.starts_with ~prefix:"s:" id then Some Contract.Requirement
  else None

let string_attribute ~loc ~name value =
  A.attribute ~loc ~name:{ txt = name; loc }
    ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc value) [] ])

let mark_expression ~name ~value expression =
  let attribute = string_attribute ~loc:expression.pexp_loc ~name value in
  { expression with pexp_attributes = attribute :: expression.pexp_attributes }

let is_linkage_attribute attribute =
  List.exists
    (String.equal attribute.attr_name.txt)
    [
      helper_attribute;
      owner_attribute;
      callee_attribute;
      upstream_attribute;
      handler_attribute;
      slot_attribute;
      nested_call_attribute;
      nested_callee_attribute;
      nested_source_attribute;
      nested_specialized_attribute;
    ]

let strip_linkage_attributes structure =
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! attributes attributes =
        List.filter
          (fun attribute -> not (is_linkage_attribute attribute))
          attributes
        |> super#attributes
    end
  in
  mapper#structure structure

let markers_in_expression expression =
  let markers = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        markers := marker_ids expression.pexp_attributes @ !markers;
        super#expression expression
    end
  in
  iterator#expression expression;
  List.rev !markers

let simple_name pattern =
  match pattern.ppat_desc with Ppat_var { txt; _ } -> Some txt | _ -> None

let primitive_name expression =
  match expression.pexp_desc with
  | Pexp_ident
      {
        txt =
          ( Longident.Ldot (Lident "Combinators", name)
          | Ldot (Ldot (Lident "Hamlet", "Combinators"), name) );
        _;
      } ->
      Some (Descriptor.Combinators, name)
  | Pexp_ident
      {
        txt =
          ( Longident.Ldot (Lident "Layer", name)
          | Ldot (Ldot (Lident "Hamlet", "Layer"), name) );
        _;
      } ->
      Some (Descriptor.Layer, name)
  | _ -> None

let combinator_name expression = Option.map snd (primitive_name expression)

let owner_descriptor expression =
  Option.bind (primitive_name expression) (fun (module_name, value_name) ->
      Descriptor.find ~module_name ~value_name)

let is_pipe expression =
  match expression.pexp_desc with
  | Pexp_ident { txt = Lident "|>"; _ } -> true
  | _ -> false

type owner_kind = Error_owner | Requirement_owner

type candidate = {
  kind : owner_kind;
  descriptor : Descriptor.t;
  form : Contract.owner_form;
  upstream : expression;
  handler : expression;
}

let owner_kind descriptor =
  match descriptor.Descriptor.channel with
  | Descriptor.Error -> Error_owner
  | Descriptor.Requirement -> Requirement_owner

let direct_candidate callee arguments =
  match owner_descriptor callee with
  | None -> None
  | Some descriptor ->
      let kind = owner_kind descriptor in
      let handlers =
        List.filter_map
          (function
            | Labelled actual, value
              when String.equal actual descriptor.handler_label ->
                Some value
            | _ -> None)
          arguments
      in
      let upstreams =
        List.filter_map
          (function Nolabel, value -> Some value | _ -> None)
          arguments
      in
      begin match (handlers, upstreams) with
      | [ handler ], [ upstream ] ->
          Some { kind; descriptor; form = Contract.Direct; upstream; handler }
      | _ -> None
      end

let candidate expression =
  match expression.pexp_desc with
  | Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ]) when is_pipe pipe
    -> (
      match right.pexp_desc with
      | Pexp_apply (callee, arguments) -> (
          match owner_descriptor callee with
          | None -> None
          | Some descriptor ->
              let kind = owner_kind descriptor in
              let handlers =
                List.filter_map
                  (function
                    | Labelled actual, value
                      when String.equal actual descriptor.handler_label ->
                        Some value
                    | _ -> None)
                  arguments
              in
              let upstreams =
                List.filter_map
                  (function Nolabel, value -> Some value | _ -> None)
                  arguments
              in
              begin match (handlers, upstreams) with
              | [ handler ], [] ->
                  Some
                    {
                      kind;
                      descriptor;
                      form = Contract.Pipe;
                      upstream = left;
                      handler;
                    }
              | _ -> None
              end)
      | _ -> None)
  | Pexp_apply (callee, arguments) -> direct_candidate callee arguments
  | _ -> None

let location_key loc =
  (loc.loc_start.pos_fname, loc.loc_start.pos_cnum, loc.loc_end.pos_cnum)

type nested_call = { id : string; loc : Location.t; source_loc : Location.t }

let nested_call_id helper loc ordinal =
  let digest =
    String.concat "\000"
      [
        helper;
        loc.loc_start.pos_fname;
        string_of_int loc.loc_start.pos_cnum;
        string_of_int loc.loc_end.pos_cnum;
        string_of_int ordinal;
      ]
    |> Digest.string
    |> Digest.to_hex
  in
  Printf.sprintf "nested:%s:%d" digest ordinal

let collect_nested_calls helper source expression =
  let calls = ref [] in
  let ordinal = ref 0 in
  let contains_source expression =
    let found = ref false in
    let iterator =
      object
        inherit Ast_traverse.iter as super

        method! expression expression =
          match expression.pexp_desc with
          | Pexp_ident { txt = Lident name; _ } when String.equal name source ->
              found := true
          | _ -> super#expression expression
      end
    in
    iterator#expression expression;
    !found
  in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        super#expression expression;
        match expression.pexp_desc with
        | Pexp_apply (callee, arguments)
          when Option.is_none (combinator_name callee) && not (is_pipe callee)
          -> (
            match
              arguments
              |> List.filter_map (function
                | Nolabel, argument when contains_source argument ->
                    Some argument
                | (Nolabel | Labelled _ | Optional _), _ -> None)
            with
            | [ source_expression ] ->
                let id = nested_call_id helper expression.pexp_loc !ordinal in
                incr ordinal;
                calls :=
                  {
                    id;
                    loc = expression.pexp_loc;
                    source_loc = source_expression.pexp_loc;
                  }
                  :: !calls
            | [] -> ()
            | _ :: _ :: _ ->
                refuse ~loc:expression.pexp_loc
                  (Invalid_nested_call
                     "the generic source flows through more than one call \
                      argument"))
        | _ -> ()
    end
  in
  iterator#expression expression;
  List.rev !calls

let attribute_value name expression =
  expression.pexp_attributes
  |> List.filter_map (fun attribute ->
      if String.equal attribute.attr_name.txt name then
        string_payload attribute.attr_payload
      else None)
  |> function
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None

let rewrite_nested_calls calls expression =
  let by_location = Hashtbl.create (List.length calls) in
  List.iter
    (fun call -> Hashtbl.add by_location (location_key call.loc) call)
    calls;
  let mapper =
    object (self)
      inherit Ast_traverse.map as super

      method! expression expression =
        match
          Hashtbl.find_opt by_location (location_key expression.pexp_loc)
        with
        | None -> super#expression expression
        | Some call ->
            begin match expression.pexp_desc with
            | Pexp_apply (callee, arguments) ->
                let callee =
                  self#expression callee
                  |> mark_expression ~name:nested_callee_attribute
                       ~value:call.id
                in
                let arguments =
                  List.map
                    (fun (label, argument) ->
                      let argument = self#expression argument in
                      if
                        label = Nolabel
                        && Location.compare argument.pexp_loc call.source_loc
                           = 0
                      then
                        ( label,
                          mark_expression ~name:nested_source_attribute
                            ~value:call.id argument )
                      else (label, argument))
                    arguments
                in
                { expression with pexp_desc = Pexp_apply (callee, arguments) }
                |> mark_expression ~name:nested_call_attribute ~value:call.id
            | _ -> assert false
            end
    end
  in
  mapper#expression expression

let cases_marker_ids cases =
  List.concat_map (fun case -> marker_ids case.pc_rhs.pexp_attributes) cases

let handler_marker_ids handler =
  match handler.pexp_desc with
  | Pexp_function (_, _, Pfunction_cases (cases, _, _)) ->
      cases_marker_ids cases
  | Pexp_function (_, _, Pfunction_body { pexp_desc = Pexp_match (_, cases); _ })
    ->
      cases_marker_ids cases
  | _ -> []

type owner = {
  marker_id : string;
  marker_loc : Location.t;
  kind : owner_kind;
  descriptor : Descriptor.t;
  form : Contract.owner_form;
  upstream : expression;
  preceding : case list;
}

let split_marker_case marker_id cases =
  let rec loop preceding = function
    | [] -> None
    | case :: rest ->
        if
          List.exists (String.equal marker_id)
            (marker_ids case.pc_rhs.pexp_attributes)
        then Some (List.rev preceding, case, rest)
        else loop (case :: preceding) rest
  in
  loop [] cases

let preceding_cases marker_id handler =
  let split cases =
    match split_marker_case marker_id cases with
    | Some (preceding, marker, []) -> Some (preceding, marker)
    | Some (_, marker, _ :: _) ->
        refuse ~loc:marker.pc_lhs.ppat_loc Unsupported_handler
    | None -> None
  in
  match handler.pexp_desc with
  | Pexp_function (_, _, Pfunction_cases (cases, _, _)) -> split cases
  | Pexp_function (_, _, Pfunction_body { pexp_desc = Pexp_match (_, cases); _ })
    ->
      split cases
  | _ -> None

let collect_owners expression =
  let owners = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        begin match candidate expression with
        | None -> ()
        | Some candidate ->
            begin match handler_marker_ids candidate.handler with
            | [] -> ()
            | [ marker_id ] ->
                begin match preceding_cases marker_id candidate.handler with
                | None ->
                    refuse ~loc:candidate.handler.pexp_loc Unsupported_handler
                | Some (preceding, marker) ->
                    owners :=
                      {
                        marker_id;
                        marker_loc = marker.pc_lhs.ppat_loc;
                        kind = candidate.kind;
                        descriptor = candidate.descriptor;
                        form = candidate.form;
                        upstream = candidate.upstream;
                        preceding;
                      }
                      :: !owners
                end
            | _ -> refuse ~loc:candidate.handler.pexp_loc Unsupported_handler
            end
        end;
        super#expression expression
    end
  in
  iterator#expression expression;
  List.rev !owners

let identifier_count name expression =
  let count = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        begin match expression.pexp_desc with
        | Pexp_ident { txt = Lident actual; _ } when String.equal name actual ->
            incr count
        | _ -> ()
        end;
        super#expression expression
    end
  in
  iterator#expression expression;
  !count

let contains_identifier name expression = identifier_count name expression > 0

let row_preserving_combinator = function
  | "catch" | "provide" | "chain" | "map" | "map_fail" | "tap" | "tap_fail"
  | "tap_defect" | "tap_cause" | "catch_defect" | "catch_cause" | "catch_filter"
  | "catch_cause_filter" | "or_die" | "thaw" | "sandbox" | "scoped"
  | "scoped_with" | "suspend" | "ensuring" | "add_finalizer"
  | "add_finalizer_exit" | "acquire_release" | "acquire_use_release" | "both" ->
      true
  | "make" | "provide_to_effect" | "provide_to_layer" | "merge_all"
  | "merge_all_with_key" | "provide_merge_to_layer" | "fresh" | "unwrap" ->
      true
  | _ -> false

let callback_effects expression =
  match expression.pexp_desc with
  | Pexp_function (_, _, Pfunction_body body) -> [ body ]
  | Pexp_function (_, _, Pfunction_cases (cases, _, _)) ->
      List.map (fun case -> case.pc_rhs) cases
  | _ -> []

let effect_arguments name arguments =
  let positional =
    List.filter_map
      (function Nolabel, expression -> Some expression | _ -> None)
      arguments
  in
  match (name, positional) with
  | "both", values -> values
  | "add_finalizer_exit", callback :: _ -> callback_effects callback
  | _, first :: _ -> [ first ]
  | _, [] -> []

let nested_source expression =
  match attribute_value nested_call_attribute expression with
  | None -> None
  | Some id -> (
      match expression.pexp_desc with
      | Pexp_apply (_, arguments) ->
          arguments
          |> List.find_map (fun (_, argument) ->
              match attribute_value nested_source_attribute argument with
              | Some source_id when String.equal source_id id -> Some argument
              | Some _ | None -> None)
      | _ -> None)

let rec supported_source_flow source expression =
  match nested_source expression with
  | Some nested -> supported_source_flow source nested
  | None -> (
      match expression.pexp_desc with
      | Pexp_ident { txt = Lident name; _ } -> String.equal source name
      | Pexp_constraint (inner, _) | Pexp_coerce (inner, _, _) ->
          supported_source_flow source inner
      | Pexp_open (_, inner) -> supported_source_flow source inner
      | Pexp_let (_, bindings, body)
        when List.for_all
               (fun binding ->
                 not (contains_identifier source binding.pvb_expr))
               bindings ->
          supported_source_flow source body
      | Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ])
        when is_pipe pipe ->
          supported_source_flow source left
          && begin match right.pexp_desc with
          | Pexp_apply (callee, _arguments) ->
              Option.fold ~none:false ~some:row_preserving_combinator
                (combinator_name callee)
          | Pexp_ident _ ->
              Option.fold ~none:false ~some:row_preserving_combinator
                (combinator_name right)
          | _ -> false
          end
      | Pexp_apply (callee, arguments) ->
          begin match combinator_name callee with
          | Some name when row_preserving_combinator name ->
              let effects = effect_arguments name arguments in
              let carrying = List.filter (contains_identifier source) effects in
              begin match carrying with
              | [ effect_expression ] ->
                  supported_source_flow source effect_expression
              | [] | _ :: _ :: _ -> false
              end
          | Some _ -> false
          | None -> (
              arguments
              |> List.filter_map (function
                | Nolabel, argument when contains_identifier source argument ->
                    Some argument
                | (Nolabel | Labelled _ | Optional _), _ -> None)
              |> function
              | [ argument ] -> supported_source_flow source argument
              | [] | _ :: _ :: _ -> false)
          end
      | _ -> false)

let parameter_names parameters =
  List.filter_map
    (fun parameter ->
      match parameter.pparam_desc with
      | Pparam_val (_, _, pattern) -> simple_name pattern
      | Pparam_newtype _ -> None)
    parameters

let other_symbolic_roots ~source ~parameters expression =
  let parameter = Hashtbl.create (List.length parameters) in
  List.iter
    (fun name ->
      if not (String.equal source name) then Hashtbl.replace parameter name ())
    parameters;
  let roots = ref [] in
  let add_root expression =
    match expression.pexp_desc with
    | Pexp_ident { txt = Lident name; _ } when Hashtbl.mem parameter name ->
        roots := name :: !roots
    | _ -> ()
  in
  let rec inspect expression =
    match nested_source expression with
    | Some nested -> inspect nested
    | None -> (
        match expression.pexp_desc with
        | Pexp_ident _ -> add_root expression
        | Pexp_constraint (inner, _)
        | Pexp_coerce (inner, _, _)
        | Pexp_open (_, inner) ->
            inspect inner
        | Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ])
          when is_pipe pipe ->
            inspect left;
            ignore right
        | Pexp_apply (callee, arguments) ->
            begin match combinator_name callee with
            | Some name when row_preserving_combinator name ->
                List.iter inspect (effect_arguments name arguments)
            | Some _ | None -> ()
            end
        | _ -> ())
  in
  inspect expression;
  List.sort_uniq String.compare !roots

let pattern_digest cases =
  Marshal.to_string cases [ Marshal.No_sharing ]
  |> Digest.string
  |> Digest.to_hex

let marker_sort left right =
  let left = left.marker_loc.loc_start in
  let right = right.marker_loc.loc_start in
  match String.compare left.pos_fname right.pos_fname with
  | 0 -> Int.compare left.pos_cnum right.pos_cnum
  | order -> order

let slot_name helper ordinal =
  Printf.sprintf "_hamlet_subtractor_%s_slot_%d" helper ordinal

let evidence_parameter ~loc helper owners =
  let patterns =
    List.mapi
      (fun ordinal _ -> A.ppat_var ~loc { txt = slot_name helper ordinal; loc })
      owners
  in
  match patterns with
  | [] -> A.ppat_any ~loc
  | [ pattern ] -> pattern
  | _ -> A.ppat_tuple ~loc patterns

let primary_binding_name marker_id =
  "_hamlet_subtractor_layer_primary_" ^ Digest.to_hex (Digest.string marker_id)

let forward_expression ~loc ~descriptor ~marker_id =
  match descriptor.Descriptor.forwarding with
  | Descriptor.Effect_fail ->
      A.pexp_ident ~loc
        { txt = Ldot (Ldot (Lident "Hamlet", "Combinators"), "fail"); loc }
  | Descriptor.Dispatch_need ->
      A.pexp_ident ~loc
        { txt = Ldot (Ldot (Lident "Hamlet", "Dispatch"), "need"); loc }
  | Descriptor.Layer_fail_like ->
      A.pexp_apply ~loc
        (A.pexp_ident ~loc
           { txt = Ldot (Ldot (Lident "Hamlet", "Layer"), "fail_like"); loc })
        [ (Nolabel, A.evar ~loc (primary_binding_name marker_id)) ]

let slot_dispatch ~loc slot =
  A.pexp_field ~loc (A.evar ~loc slot)
    {
      txt = Ldot (Ldot (Lident "Hamlet_subtractor", "Evidence"), "dispatch");
      loc;
    }

let forwarding_fallback ~loc forward_name =
  let value_name = "_hamlet_subtractor_guarded_value" in
  A.case
    ~lhs:(A.ppat_var ~loc { txt = value_name; loc })
    ~guard:None
    ~rhs:
      (A.pexp_apply ~loc (A.evar ~loc forward_name)
         [ (Nolabel, A.evar ~loc value_name) ])

let handled_callback ~loc ~forward_name cases =
  let cases =
    if List.exists (fun case -> Option.is_some case.pc_guard) cases then
      cases @ [ forwarding_fallback ~loc forward_name ]
    else cases
  in
  let cases =
    match cases with
    | [] ->
        [
          A.case ~lhs:(A.ppat_any ~loc) ~guard:None
            ~rhs:(A.pexp_assert ~loc (A.ebool ~loc false));
        ]
    | _ -> cases
  in
  A.pexp_function ~loc [] None (Pfunction_cases (cases, loc, []))

let dispatch_expression ~loc ~marker_id ~slot ~descriptor input cases =
  let forward_name = "_hamlet_subtractor_forward" in
  let forward = forward_expression ~loc ~descriptor ~marker_id in
  let handled = handled_callback ~loc ~forward_name cases in
  let dispatch =
    A.pexp_apply ~loc (slot_dispatch ~loc slot)
      [
        (Nolabel, input);
        (Labelled "handled", handled);
        (Labelled "forward", A.evar ~loc forward_name);
      ]
    |> mark_expression ~name:slot_attribute ~value:marker_id
  in
  let binding =
    A.value_binding ~loc
      ~pat:(A.ppat_var ~loc { txt = forward_name; loc })
      ~expr:forward
  in
  A.pexp_let ~loc Nonrecursive [ binding ] dispatch

let rewrite_handler ~marker_id ~slot ~descriptor handler =
  let rewritten = ref false in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        if !rewritten then super#expression expression
        else
          match expression.pexp_desc with
          | Pexp_function
              (parameters, constraint_, Pfunction_cases (cases, _, _)) ->
              begin match split_marker_case marker_id cases with
              | Some (preceding, _, []) ->
                  rewritten := true;
                  let loc = expression.pexp_loc in
                  let argument = "_hamlet_subtractor_input" in
                  let parameter =
                    A.pparam_val ~loc Nolabel None
                      (A.ppat_var ~loc { txt = argument; loc })
                  in
                  {
                    expression with
                    pexp_desc =
                      Pexp_function
                        ( parameters @ [ parameter ],
                          constraint_,
                          Pfunction_body
                            (dispatch_expression ~loc ~marker_id ~slot
                               ~descriptor (A.evar ~loc argument) preceding) );
                  }
              | Some (_, marker, _ :: _) ->
                  refuse ~loc:marker.pc_lhs.ppat_loc Unsupported_handler
              | None -> super#expression expression
              end
          | Pexp_match (input, cases) ->
              begin match split_marker_case marker_id cases with
              | Some (preceding, _, []) ->
                  rewritten := true;
                  dispatch_expression ~loc:expression.pexp_loc ~marker_id ~slot
                    ~descriptor (super#expression input) preceding
              | Some (_, marker, _ :: _) ->
                  refuse ~loc:marker.pc_lhs.ppat_loc Unsupported_handler
              | None -> super#expression expression
              end
          | _ -> super#expression expression
    end
  in
  let handler = mapper#expression handler in
  if not !rewritten then refuse ~loc:handler.pexp_loc Unsupported_handler;
  handler

let replace_handler_argument marker_id slot descriptor arguments =
  List.map
    (fun (label, expression) ->
      match label with
      | Labelled actual
        when String.equal actual descriptor.Descriptor.handler_label ->
          ( label,
            rewrite_handler ~marker_id ~slot ~descriptor expression
            |> mark_expression ~name:handler_attribute ~value:marker_id )
      | Labelled actual
        when Option.equal String.equal descriptor.required_label (Some actual)
        ->
          ( label,
            mark_expression ~name:Hamlet_subtractor_probe.contributor_attribute
              ~value:marker_id expression )
      | Nolabel | Labelled _ | Optional _ -> (label, expression))
    arguments

let rewrite_markers helper owners expression =
  let slots = Hashtbl.create (List.length owners) in
  List.iteri
    (fun ordinal owner ->
      Hashtbl.add slots owner.marker_id (slot_name helper ordinal, owner))
    owners;
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        let expression = super#expression expression in
        match candidate expression with
        | None -> expression
        | Some candidate ->
            begin match handler_marker_ids candidate.handler with
            | [ marker_id ] ->
                begin match Hashtbl.find_opt slots marker_id with
                | None -> expression
                | Some (slot, owner) ->
                    let descriptor = owner.descriptor in
                    let replace right =
                      match right.pexp_desc with
                      | Pexp_apply (callee, arguments) ->
                          let callee =
                            mark_expression ~name:callee_attribute
                              ~value:marker_id callee
                          in
                          {
                            right with
                            pexp_desc =
                              Pexp_apply
                                ( callee,
                                  replace_handler_argument marker_id slot
                                    descriptor arguments );
                          }
                      | _ -> right
                    in
                    begin match expression.pexp_desc with
                    | Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ])
                      when is_pipe pipe ->
                        let left =
                          mark_expression ~name:upstream_attribute
                            ~value:marker_id left
                        in
                        let left, binding =
                          if descriptor.bind_upstream_once then
                            let name = primary_binding_name marker_id in
                            ( A.evar ~loc:left.pexp_loc name,
                              Some
                                (A.value_binding ~loc:left.pexp_loc
                                   ~pat:
                                     (A.ppat_var ~loc:left.pexp_loc
                                        { txt = name; loc = left.pexp_loc })
                                   ~expr:left) )
                          else (left, None)
                        in
                        let rewritten =
                          {
                            expression with
                            pexp_desc =
                              Pexp_apply
                                ( pipe,
                                  [ (Nolabel, left); (Nolabel, replace right) ]
                                );
                          }
                        in
                        let rewritten =
                          match binding with
                          | Some binding ->
                              A.pexp_let ~loc:expression.pexp_loc Nonrecursive
                                [ binding ] rewritten
                          | None -> rewritten
                        in
                        mark_expression ~name:owner_attribute ~value:marker_id
                          rewritten
                    | Pexp_apply (callee, arguments) ->
                        let callee =
                          mark_expression ~name:callee_attribute
                            ~value:marker_id callee
                        in
                        let arguments =
                          replace_handler_argument marker_id slot descriptor
                            arguments
                        in
                        let binding = ref None in
                        let marked = ref false in
                        let arguments =
                          List.map
                            (fun (label, argument) ->
                              match (label, !marked) with
                              | Nolabel, false ->
                                  marked := true;
                                  let argument =
                                    mark_expression ~name:upstream_attribute
                                      ~value:marker_id argument
                                  in
                                  if descriptor.bind_upstream_once then (
                                    let name = primary_binding_name marker_id in
                                    binding :=
                                      Some
                                        (A.value_binding ~loc:argument.pexp_loc
                                           ~pat:
                                             (A.ppat_var ~loc:argument.pexp_loc
                                                {
                                                  txt = name;
                                                  loc = argument.pexp_loc;
                                                })
                                           ~expr:argument);
                                    (label, A.evar ~loc:argument.pexp_loc name))
                                  else (label, argument)
                              | (Nolabel | Labelled _ | Optional _), _ ->
                                  (label, argument))
                            arguments
                        in
                        let rewritten =
                          {
                            expression with
                            pexp_desc = Pexp_apply (callee, arguments);
                          }
                        in
                        let rewritten =
                          match !binding with
                          | Some binding ->
                              A.pexp_let ~loc:expression.pexp_loc Nonrecursive
                                [ binding ] rewritten
                          | None -> rewritten
                        in
                        mark_expression ~name:owner_attribute ~value:marker_id
                          rewritten
                    | _ -> expression
                    end
                end
            | [] | _ :: _ :: _ -> expression
            end
    end
  in
  mapper#expression expression

let remove_generic_attribute attributes =
  List.filter
    (fun attribute ->
      not (String.equal attribute.attr_name.txt generic_attribute))
    attributes

let generic_attributes binding =
  List.filter
    (fun attribute -> String.equal attribute.attr_name.txt generic_attribute)
    binding.pvb_attributes

let contract_slot ordinal owner =
  let kind =
    match owner.kind with
    | Error_owner -> Contract.Error
    | Requirement_owner -> Contract.Requirement
  in
  {
    Contract.ordinal;
    marker_id = owner.marker_id;
    kind;
    owner_form = owner.form;
    handled_cases = List.length owner.preceding;
    guarded =
      List.exists (fun case -> Option.is_some case.pc_guard) owner.preceding;
    handled_digest = pattern_digest owner.preceding;
  }

let contract_attribute ~loc payload =
  A.attribute ~loc
    ~name:{ txt = Contract.attribute_name; loc }
    ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc payload) [] ])

let companion ~loc name payload =
  let binding =
    A.module_binding ~loc ~name:{ txt = Some name; loc }
      ~expr:(A.pmod_structure ~loc [])
  in
  let binding =
    { binding with pmb_attributes = [ contract_attribute ~loc payload ] }
  in
  A.pstr_module ~loc binding

let rewrite_binding binding =
  let attributes = generic_attributes binding in
  match attributes with
  | [] -> None
  | _ :: _ :: _ -> refuse ~loc:binding.pvb_loc Duplicate_annotation
  | [ attribute ] ->
      if attribute.attr_payload <> PStr [] then
        refuse ~loc:attribute.attr_loc Invalid_annotation_payload;
      let helper =
        match simple_name binding.pvb_pat with
        | Some name -> name
        | None -> refuse ~loc:binding.pvb_pat.ppat_loc Anonymous_binding
      in
      begin match binding.pvb_expr.pexp_desc with
      | Pexp_function (parameters, constraint_, Pfunction_body body) ->
          let value_parameters =
            List.filter_map
              (fun parameter ->
                match parameter.pparam_desc with
                | Pparam_val (label, default, pattern) ->
                    Some (parameter, label, default, pattern)
                | Pparam_newtype _ -> None)
              parameters
          in
          let source_parameter = List.length value_parameters - 1 in
          if source_parameter < 0 then
            refuse ~loc:binding.pvb_expr.pexp_loc Missing_source_parameter;
          let _, label, default, source_pattern =
            List.hd (List.rev value_parameters)
          in
          let source =
            match (label, default, simple_name source_pattern) with
            | Nolabel, None, Some name -> name
            | _ ->
                refuse ~loc:source_pattern.ppat_loc Unsupported_source_parameter
          in
          let nested_calls = collect_nested_calls helper source body in
          let body = rewrite_nested_calls nested_calls body in
          let count = identifier_count source body in
          if count <> 1 then
            refuse ~loc:source_pattern.ppat_loc (Source_not_linear count);
          let all_markers = markers_in_expression body in
          if all_markers = [] && nested_calls = [] then
            refuse ~loc:binding.pvb_loc No_automatic_markers;
          let owners = collect_owners body |> List.sort marker_sort in
          let owned = List.map (fun owner -> owner.marker_id) owners in
          if
            List.exists
              (fun marker -> not (List.exists (String.equal marker) owned))
              all_markers
          then refuse ~loc:binding.pvb_loc Marker_without_supported_owner;
          List.iter
            (fun owner ->
              let expected =
                match owner.kind with
                | Error_owner -> Contract.Error
                | Requirement_owner -> Contract.Requirement
              in
              if marker_kind owner.marker_id <> Some expected then
                refuse ~loc:owner.marker_loc Wrong_marker_channel;
              if not (supported_source_flow source owner.upstream) then
                refuse ~loc:owner.upstream.pexp_loc Unsupported_source_flow;
              let other_roots =
                other_symbolic_roots ~source
                  ~parameters:(parameter_names parameters)
                  owner.upstream
              in
              if other_roots <> [] then
                refuse ~loc:owner.upstream.pexp_loc
                  (Multiple_symbolic_inputs other_roots))
            owners;
          if not (supported_source_flow source body) then
            refuse ~loc:body.pexp_loc Unsupported_source_flow;
          let body = rewrite_markers helper owners body in
          let evidence =
            evidence_parameter ~loc:binding.pvb_expr.pexp_loc helper owners
          in
          let evidence_parameter =
            A.pparam_val ~loc:binding.pvb_expr.pexp_loc Nolabel None evidence
          in
          let expression =
            {
              binding.pvb_expr with
              pexp_desc =
                Pexp_function
                  ( parameters @ [ evidence_parameter ],
                    constraint_,
                    Pfunction_body body );
            }
          in
          let binding =
            {
              binding with
              pvb_expr = expression;
              pvb_attributes = remove_generic_attribute binding.pvb_attributes;
            }
          in
          let contract =
            Contract.
              {
                helper;
                source_parameter;
                slots = List.mapi contract_slot owners;
              }
          in
          let payload =
            match Contract.encode_provisional contract with
            | Ok payload -> payload
            | Error message ->
                refuse ~loc:binding.pvb_loc (Contract_encoding_failed message)
          in
          let helper_link =
            `Assoc
              [
                ("helper", `String helper);
                ("source_parameter", `Int source_parameter);
              ]
            |> Yojson.Safe.to_string
          in
          let helper_attribute =
            string_attribute ~loc:binding.pvb_loc ~name:helper_attribute
              helper_link
          in
          let binding =
            {
              binding with
              pvb_attributes = helper_attribute :: binding.pvb_attributes;
            }
          in
          Some (helper, binding, payload)
      | Pexp_function (_, _, Pfunction_cases _) | _ ->
          refuse ~loc:binding.pvb_expr.pexp_loc Not_a_function
      end

let top_level_modules structure =
  List.filter_map
    (fun item ->
      match item.pstr_desc with
      | Pstr_module { pmb_name = { txt = Some name; _ }; _ } -> Some name
      | _ -> None)
    structure

let rewrite structure =
  try
    let modules = Hashtbl.create 16 in
    List.iter
      (fun name -> Hashtbl.replace modules name ())
      (top_level_modules structure);
    let helpers = Hashtbl.create 16 in
    let rewrite_item item =
      match item.pstr_desc with
      | Pstr_value (recursive, bindings) ->
          let has_generic =
            List.exists
              (fun binding -> generic_attributes binding <> [])
              bindings
          in
          if has_generic && recursive = Recursive then
            refuse ~loc:item.pstr_loc Recursive_binding;
          let companions = ref [] in
          let bindings =
            List.map
              (fun binding ->
                match rewrite_binding binding with
                | None -> binding
                | Some (helper, binding, payload) ->
                    if Hashtbl.mem helpers helper then
                      refuse ~loc:binding.pvb_loc (Duplicate_helper helper);
                    Hashtbl.add helpers helper ();
                    let name = Contract.companion_name helper in
                    if Hashtbl.mem modules name then
                      refuse ~loc:binding.pvb_loc (Companion_collision name);
                    Hashtbl.add modules name ();
                    companions :=
                      companion ~loc:binding.pvb_loc name payload :: !companions;
                    binding)
              bindings
          in
          { item with pstr_desc = Pstr_value (recursive, bindings) }
          :: List.rev !companions
      | _ -> [ item ]
    in
    Ok (List.concat_map rewrite_item structure)
  with Refusal refusal -> Error refusal

let rewrite_exn structure =
  match rewrite structure with
  | Ok structure -> structure
  | Error { loc; reason } ->
      Location.raise_errorf ~loc "generic automatic propagation: %s"
        (refusal_message reason)

type composition_finalization_error =
  | Missing_definition_attachment of string
  | Duplicate_definition_attachment of string
  | Invalid_definition_attachment of string
  | Invalid_helper_link
  | Missing_nested_slots of string
  | Invalid_generated_evidence_parameter of string

let composition_finalization_error_message = function
  | Missing_definition_attachment helper ->
      "missing exact contract attachment for generic helper " ^ helper
  | Duplicate_definition_attachment helper ->
      "duplicate exact contract attachment for generic helper " ^ helper
  | Invalid_definition_attachment helper ->
      "invalid exact contract attachment for generic helper " ^ helper
  | Invalid_helper_link -> "invalid generic-helper definition linkage"
  | Missing_nested_slots id ->
      "composed contract has no evidence slots for nested call " ^ id
  | Invalid_generated_evidence_parameter helper ->
      "cannot replace the generated evidence parameter for helper " ^ helper

let helper_name_from_attributes attributes =
  attributes
  |> List.filter_map (fun attribute ->
      if String.equal attribute.attr_name.txt helper_attribute then
        string_payload attribute.attr_payload
      else None)
  |> function
  | [ payload ] -> (
      try
        match Yojson.Safe.from_string payload with
        | `Assoc fields -> (
            match List.assoc_opt "helper" fields with
            | Some (`String helper) -> Some helper
            | Some _ | None -> None)
        | _ -> None
      with Yojson.Json_error _ -> None)
  | [] | _ :: _ :: _ -> None

let definition_contract attachments helper =
  let module Protocol = Hamlet_subtractor_core.Protocol in
  let id = "definition:" ^ helper in
  attachments
  |> List.filter (fun attachment ->
      String.equal id (Protocol.generic_attachment_id attachment)
      && Protocol.generic_attachment_kind attachment = Protocol.Definition)
  |> function
  | [] -> Error (Missing_definition_attachment helper)
  | _ :: _ :: _ -> Error (Duplicate_definition_attachment helper)
  | [ attachment ] ->
      Protocol.generic_attachment_payload attachment
      |> Hamlet_subtractor_core.Generic_resolution.decode_definition
      |> Result.map_error (fun _ -> Invalid_definition_attachment helper)

let starts_with_namespace namespace id =
  let prefix = namespace ^ "/" in
  String.starts_with ~prefix id

let final_slot_pattern ~loc helper slots =
  let patterns =
    List.map
      (fun slot ->
        let ordinal =
          Hamlet_subtractor_core.Generic_contract.slot_ordinal slot
        in
        A.ppat_var ~loc { txt = slot_name helper ordinal; loc })
      slots
  in
  match patterns with
  | [] -> A.ppat_any ~loc
  | [ pattern ] -> pattern
  | _ -> A.ppat_tuple ~loc patterns

let projection_expression ~loc helper slots =
  let expressions =
    List.map
      (fun slot ->
        let ordinal =
          Hamlet_subtractor_core.Generic_contract.slot_ordinal slot
        in
        A.evar ~loc (slot_name helper ordinal))
      slots
  in
  match expressions with
  | [] -> assert false
  | [ expression ] -> expression
  | _ -> A.pexp_tuple ~loc expressions

let finalize_helper_composition ~helper ~contract expression =
  let module Generic_contract = Hamlet_subtractor_core.Generic_contract in
  let slots = Generic_contract.slots contract in
  let nested_calls = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        begin match attribute_value nested_call_attribute expression with
        | Some id -> nested_calls := id :: !nested_calls
        | None -> ()
        end;
        super#expression expression
    end
  in
  iterator#expression expression;
  let nested_calls = List.sort_uniq String.compare !nested_calls in
  let validate_nested id =
    let nested_slots =
      List.filter
        (fun slot ->
          Generic_contract.slot_id_value slot
          |> Generic_contract.slot_id_to_string
          |> starts_with_namespace id)
        slots
    in
    if nested_slots = [] then Error (Missing_nested_slots id) else Ok ()
  in
  let rec validate = function
    | [] -> Ok ()
    | id :: rest -> (
        match validate_nested id with
        | Error _ as error -> error
        | Ok () -> validate rest)
  in
  match validate nested_calls with
  | Error _ as error -> error
  | Ok () ->
      let mapper =
        object
          inherit Ast_traverse.map as super

          method! expression expression =
            match attribute_value nested_call_attribute expression with
            | None -> super#expression expression
            | Some id ->
                let nested_slots =
                  List.filter
                    (fun slot ->
                      Generic_contract.slot_id_value slot
                      |> Generic_contract.slot_id_to_string
                      |> starts_with_namespace id)
                    slots
                in
                let evidence =
                  projection_expression ~loc:expression.pexp_loc helper
                    nested_slots
                in
                let expression = super#expression expression in
                begin match expression.pexp_desc with
                | Pexp_apply (callee, arguments) ->
                    {
                      expression with
                      pexp_desc =
                        Pexp_apply (callee, arguments @ [ (Nolabel, evidence) ]);
                    }
                | _ -> expression
                end
        end
      in
      let expression = mapper#expression expression in
      begin match expression.pexp_desc with
      | Pexp_function (parameters, constraint_, body) -> (
          match List.rev parameters with
          | ({ pparam_desc = Pparam_val (Nolabel, None, _); _ } as evidence)
            :: rest ->
              let evidence =
                {
                  evidence with
                  pparam_desc =
                    Pparam_val
                      ( Nolabel,
                        None,
                        final_slot_pattern ~loc:evidence.pparam_loc helper slots
                      );
                }
              in
              Ok
                {
                  expression with
                  pexp_desc =
                    Pexp_function
                      (List.rev (evidence :: rest), constraint_, body);
                }
          | _ -> Error (Invalid_generated_evidence_parameter helper))
      | _ -> Error (Invalid_generated_evidence_parameter helper)
      end

let finalize_composition ~attachments structure =
  let error = ref None in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! value_binding binding =
        match helper_name_from_attributes binding.pvb_attributes with
        | None -> super#value_binding binding
        | Some helper -> (
            match definition_contract attachments helper with
            | Error reason ->
                error := Some reason;
                binding
            | Ok contract -> (
                match
                  finalize_helper_composition ~helper ~contract binding.pvb_expr
                with
                | Error reason ->
                    error := Some reason;
                    binding
                | Ok expression ->
                    super#value_binding { binding with pvb_expr = expression }))
    end
  in
  let structure = mapper#structure structure in
  match !error with None -> Ok structure | Some reason -> Error reason
