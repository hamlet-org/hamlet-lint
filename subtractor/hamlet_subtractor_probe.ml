module Compiler_parsetree = Parsetree
module Compiler_path = Path
module Compiler_tast_iterator = Tast_iterator
module Compiler_typedtree = Typedtree
module Compiler_types = Types

open Ppxlib
module A = Ast_builder.Default
module Descriptor = Hamlet_subtractor_core.Owner_descriptor

let marker_attribute = "hamlet.subtractor.marker.v1"
let upstream_attribute = "hamlet.subtractor.upstream.v1"
let callee_attribute = "hamlet.subtractor.callee.v1"
let handler_attribute = "hamlet.subtractor.handler.v1"
let owner_attribute = "hamlet.subtractor.owner.v1"
let generic_output_link_attribute = "hamlet.subtractor.generic_output_link.v1"
let layer_forwarding_attribute = "hamlet.subtractor.layer_forwarding.v1"
let layer_type_attribute = "hamlet.subtractor.layer_type.v1"
let contributor_attribute = "hamlet.subtractor.contributor.v1"

type propagation_kind = Error_propagation | Requirement_propagation

type marker = {
  id : string;
  original_id : string;
  kind : propagation_kind;
  loc : Location.t;
}

type owner_form = Direct | Pipe

type owner = {
  marker : marker;
  form : owner_form;
  call_loc : Location.t;
  upstream_loc : Location.t;
  handler_loc : Location.t;
}

type refusal_reason =
  | No_supported_owner
  | Named_handler
  | Ambiguous_owner
  | Unsupported_call_shape
  | Wrong_channel of { owner : propagation_kind; marker : propagation_kind }

type refusal = { marker : marker; reason : refusal_reason; loc : Location.t }

type prepared = {
  base_structure : structure;
  probe_structure : structure;
  structure : structure;
  markers : marker list;
  owners : owner list;
  refusals : refusal list;
}

let propagation_kind_of_id id =
  if String.starts_with ~prefix:"e:" id then Some Error_propagation
  else if String.starts_with ~prefix:"s:" id then Some Requirement_propagation
  else None

let propagation_prefix = function
  | Error_propagation -> "e"
  | Requirement_propagation -> "s"

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

let marker_values attributes =
  List.filter_map
    (fun attribute ->
      if String.equal attribute.attr_name.txt marker_attribute then
        string_payload attribute.attr_payload
      else None)
    attributes

let canonical_id ~structure_digest ~kind ~loc ~ordinal =
  let filename = loc.loc_start.pos_fname in
  let identity =
    String.concat "\000"
      [
        structure_digest;
        filename;
        propagation_prefix kind;
        string_of_int loc.loc_start.pos_cnum;
        string_of_int loc.loc_end.pos_cnum;
        string_of_int ordinal;
      ]
  in
  Printf.sprintf "%s:%s:%d" (propagation_prefix kind)
    (Digest.to_hex (Digest.string identity))
    ordinal

let canonicalize_markers structure =
  let structure_digest =
    Marshal.to_string structure [ Marshal.No_sharing ]
    |> Digest.string
    |> Digest.to_hex
  in
  let ordinals = Hashtbl.create 16 in
  let markers = ref [] in
  let next_ordinal kind loc =
    let key =
      ( kind,
        loc.loc_start.pos_fname,
        loc.loc_start.pos_cnum,
        loc.loc_end.pos_cnum )
    in
    let ordinal = Option.value (Hashtbl.find_opt ordinals key) ~default:0 in
    Hashtbl.replace ordinals key (ordinal + 1);
    ordinal
  in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        let attributes =
          List.map
            (fun attribute ->
              if not (String.equal attribute.attr_name.txt marker_attribute)
              then attribute
              else
                match string_payload attribute.attr_payload with
                | None -> attribute
                | Some original_id -> (
                    match propagation_kind_of_id original_id with
                    | None -> attribute
                    | Some kind ->
                        let ordinal = next_ordinal kind expression.pexp_loc in
                        let id =
                          canonical_id ~structure_digest ~kind
                            ~loc:expression.pexp_loc ~ordinal
                        in
                        markers :=
                          { id; original_id; kind; loc = expression.pexp_loc }
                          :: !markers;
                        {
                          attribute with
                          attr_payload =
                            PStr
                              [
                                A.pstr_eval ~loc:attribute.attr_loc
                                  (A.estring ~loc:attribute.attr_loc id)
                                  [];
                              ];
                        }))
            expression.pexp_attributes
        in
        super#expression { expression with pexp_attributes = attributes }
    end
  in
  let structure = mapper#structure structure in
  (structure, List.rev !markers)

let descriptor_of_written_path = function
  | Longident.Ldot (Lident module_name, value_name)
  | Ldot (Ldot (Lident "Hamlet", module_name), value_name) ->
      let module_name =
        match module_name with
        | "Combinators" -> Some Descriptor.Combinators
        | "Layer" -> Some Descriptor.Layer
        | _ -> None
      in
      Option.bind module_name (fun module_name ->
          Descriptor.find ~module_name ~value_name)
  | _ -> None

let owner_descriptor expression =
  match expression.pexp_desc with
  | Pexp_ident { txt; _ } -> descriptor_of_written_path txt
  | _ -> None

let propagation_kind_of_descriptor descriptor =
  match descriptor.Descriptor.channel with
  | Descriptor.Error -> Error_propagation
  | Descriptor.Requirement -> Requirement_propagation

let is_pipe expression =
  match expression.pexp_desc with
  | Pexp_ident { txt = Lident "|>"; _ } -> true
  | _ -> false

let is_loc_argument = function
  | Labelled "loc", _ | Optional "loc", _ -> true
  | _ -> false

type candidate =
  | Direct_candidate of {
      descriptor : Descriptor.t;
      call : expression;
      callee : expression;
      args : (arg_label * expression) list;
      upstream_index : int;
      upstream : expression;
      handler : expression;
    }
  | Pipe_candidate of {
      descriptor : Descriptor.t;
      call : expression;
      pipe : expression;
      left : expression;
      right : expression;
      handler : expression;
    }

type candidate_status =
  | Candidate of candidate
  | Partial_candidate
  | Unsupported_candidate of propagation_kind
  | Not_candidate

let indexed arguments =
  List.mapi (fun index argument -> (index, argument)) arguments

let direct_candidate call callee args descriptor =
  let handlers =
    List.filter_map
      (fun (_, (label, argument)) ->
        match label with
        | Labelled actual
          when String.equal actual descriptor.Descriptor.handler_label ->
            Some argument
        | _ -> None)
      (indexed args)
  in
  let upstreams =
    List.filter_map
      (fun (index, (label, argument)) ->
        match label with Nolabel -> Some (index, argument) | _ -> None)
      (indexed args)
  in
  let valid_labels =
    List.for_all
      (function
        | Nolabel, _ -> true
        | Labelled actual, _
          when String.equal actual descriptor.Descriptor.handler_label ->
            true
        | Labelled actual, _
          when Option.equal String.equal descriptor.required_label (Some actual)
          ->
            true
        | (Labelled "fresh" | Optional "fresh"), _
          when descriptor.bind_upstream_once ->
            true
        | argument -> is_loc_argument argument)
      args
  in
  let has_required_label =
    match descriptor.required_label with
    | None -> true
    | Some required ->
        List.exists
          (function
            | Labelled actual, _ -> String.equal actual required | _ -> false)
          args
  in
  match (handlers, upstreams, valid_labels, has_required_label) with
  | [ handler ], [ (upstream_index, upstream) ], true, true ->
      Candidate
        (Direct_candidate
           { descriptor; call; callee; args; upstream_index; upstream; handler })
  | [ _ ], [], true, true -> Partial_candidate
  | _ -> Unsupported_candidate (propagation_kind_of_descriptor descriptor)

let pipe_candidate call pipe left right =
  match right.pexp_desc with
  | Pexp_apply (callee, args) -> (
      match owner_descriptor callee with
      | None -> Not_candidate
      | Some descriptor -> (
          let handlers =
            List.filter_map
              (function
                | Labelled actual, handler
                  when String.equal actual descriptor.handler_label ->
                    Some handler
                | _ -> None)
              args
          in
          let has_upstream =
            List.exists (function Nolabel, _ -> true | _ -> false) args
          in
          let valid_labels =
            List.for_all
              (function
                | Labelled actual, _
                  when String.equal actual descriptor.handler_label ->
                    true
                | Labelled actual, _
                  when Option.equal String.equal descriptor.required_label
                         (Some actual) ->
                    true
                | (Labelled "fresh" | Optional "fresh"), _
                  when descriptor.bind_upstream_once ->
                    true
                | argument -> is_loc_argument argument)
              args
          in
          let has_required_label =
            match descriptor.required_label with
            | None -> true
            | Some required ->
                List.exists
                  (function
                    | Labelled actual, _ -> String.equal actual required
                    | _ -> false)
                  args
          in
          match (handlers, has_upstream, valid_labels, has_required_label) with
          | [ handler ], false, true, true ->
              Candidate
                (Pipe_candidate { descriptor; call; pipe; left; right; handler })
          | _ ->
              Unsupported_candidate (propagation_kind_of_descriptor descriptor))
      )
  | _ -> Not_candidate

let candidate_status expression =
  match expression.pexp_desc with
  | Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ]) when is_pipe pipe
    ->
      pipe_candidate expression pipe left right
  | Pexp_apply (callee, args) -> (
      match owner_descriptor callee with
      | Some descriptor -> direct_candidate expression callee args descriptor
      | None -> Not_candidate)
  | _ -> Not_candidate

let candidate_kind = function
  | Direct_candidate { descriptor; _ } | Pipe_candidate { descriptor; _ } ->
      propagation_kind_of_descriptor descriptor

let candidate_descriptor = function
  | Direct_candidate { descriptor; _ } | Pipe_candidate { descriptor; _ } ->
      descriptor

let candidate_call = function
  | Direct_candidate { call; _ } | Pipe_candidate { call; _ } -> call

let candidate_upstream = function
  | Direct_candidate { upstream; _ } -> upstream
  | Pipe_candidate { left; _ } -> left

let candidate_handler = function
  | Direct_candidate { handler; _ } | Pipe_candidate { handler; _ } -> handler

let candidate_form = function
  | Direct_candidate _ -> Direct
  | Pipe_candidate _ -> Pipe

let inline_handler expression =
  match expression.pexp_desc with Pexp_function _ -> true | _ -> false

let markers_in_expression expression =
  let markers = ref [] in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        markers := marker_values expression.pexp_attributes @ !markers;
        super#expression expression
    end
  in
  iterator#expression expression;
  List.rev !markers

let simple_pattern_name pattern =
  match pattern.ppat_desc with Ppat_var { txt; _ } -> Some txt | _ -> None

let named_handler_name expression =
  match expression.pexp_desc with
  | Pexp_ident { txt = Lident name; _ } -> Some name
  | _ -> None

let named_handler_refusals markers structure =
  let binding_markers = Hashtbl.create 16 in
  let named_calls = Hashtbl.create 16 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! value_binding binding =
        Option.iter
          (fun name ->
            let ids = markers_in_expression binding.pvb_expr in
            if ids <> [] then Hashtbl.add binding_markers name ids)
          (simple_pattern_name binding.pvb_pat);
        super#value_binding binding

      method! expression expression =
        (match candidate_status expression with
        | Candidate candidate ->
            Option.iter
              (fun name ->
                let count =
                  Option.value (Hashtbl.find_opt named_calls name) ~default:0
                in
                Hashtbl.replace named_calls name (count + 1))
              (named_handler_name (candidate_handler candidate))
        | Partial_candidate | Unsupported_candidate _ | Not_candidate -> ());
        super#expression expression
    end
  in
  iterator#structure structure;
  let by_id = Hashtbl.create (List.length markers) in
  List.iter (fun marker -> Hashtbl.replace by_id marker.id marker) markers;
  let refusals = ref [] in
  Hashtbl.iter
    (fun name ids ->
      match Hashtbl.find_opt named_calls name with
      | None -> ()
      | Some call_count ->
          List.iter
            (fun id ->
              Option.iter
                (fun (marker : marker) ->
                  let reason =
                    if call_count = 1 then Named_handler else Ambiguous_owner
                  in
                  refusals := { marker; reason; loc = marker.loc } :: !refusals)
                (Hashtbl.find_opt by_id id))
            ids)
    binding_markers;
  List.rev !refusals

let upstream_attribute_value kind id =
  match propagation_kind_of_id id with
  | Some marker_kind when marker_kind = kind -> id
  | Some _ | None -> propagation_prefix kind ^ ":" ^ id

let add_string_attribute ~name ~value expression =
  let loc = expression.pexp_loc in
  let attribute =
    A.attribute ~loc ~name:{ txt = name; loc }
      ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc value) [] ])
  in
  { expression with pexp_attributes = attribute :: expression.pexp_attributes }

let add_upstream_attribute ~kind ~id expression =
  add_string_attribute ~name:upstream_attribute
    ~value:(upstream_attribute_value kind id)
    expression

let descriptor_uses_layer_type descriptor =
  descriptor.Descriptor.module_name = Descriptor.Layer
  && not (String.equal descriptor.value_name "provide_to_effect")

let add_layer_type_attribute descriptor ~id expression =
  if descriptor_uses_layer_type descriptor then
    add_string_attribute ~name:layer_type_attribute ~value:id expression
  else expression

let add_evidence_attribute ~name ~id expression =
  add_string_attribute ~name ~value:id expression

let once_binding_name id =
  "_hamlet_subtractor_layer_primary_" ^ Digest.to_hex (Digest.string id)

let add_value_binding_attribute ~name ~id binding =
  let loc = binding.pvb_loc in
  let attribute =
    A.attribute ~loc ~name:{ txt = name; loc }
      ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc id) [] ])
  in
  { binding with pvb_attributes = attribute :: binding.pvb_attributes }

let replace_direct_upstream upstream_index replacement args =
  List.mapi
    (fun index (label, argument) ->
      if index = upstream_index then (label, replacement) else (label, argument))
    args

let mark_base_candidate candidate marker =
  let kind = candidate_kind candidate in
  let id = marker.id in
  match candidate with
  | Direct_candidate
      { descriptor; call; callee; args; upstream_index; upstream; _ } ->
      let upstream =
        add_upstream_attribute ~kind ~id upstream
        |> add_layer_type_attribute descriptor ~id
      in
      if descriptor.bind_upstream_once then
        let name = once_binding_name id in
        let binding =
          A.value_binding ~loc:upstream.pexp_loc
            ~pat:
              (A.ppat_var ~loc:upstream.pexp_loc
                 { txt = name; loc = upstream.pexp_loc })
            ~expr:upstream
        in
        let replacement = A.evar ~loc:upstream.pexp_loc name in
        let call =
          {
            call with
            pexp_desc =
              Pexp_apply
                (callee, replace_direct_upstream upstream_index replacement args);
          }
        in
        A.pexp_let ~loc:call.pexp_loc Nonrecursive [ binding ] call
        |> add_layer_type_attribute descriptor ~id
        |> add_evidence_attribute ~name:owner_attribute ~id
        |> add_evidence_attribute ~name:layer_forwarding_attribute ~id
      else
        let args = replace_direct_upstream upstream_index upstream args in
        let call =
          add_evidence_attribute ~name:owner_attribute ~id call
          |> add_layer_type_attribute descriptor ~id
        in
        { call with pexp_desc = Pexp_apply (callee, args) }
  | Pipe_candidate { descriptor; call; pipe; left; right; _ } ->
      let left =
        add_upstream_attribute ~kind ~id left
        |> add_layer_type_attribute descriptor ~id
      in
      if descriptor.bind_upstream_once then
        let name = once_binding_name id in
        let binding =
          A.value_binding ~loc:left.pexp_loc
            ~pat:
              (A.ppat_var ~loc:left.pexp_loc
                 { txt = name; loc = left.pexp_loc })
            ~expr:left
        in
        let replacement = A.evar ~loc:left.pexp_loc name in
        let call =
          {
            call with
            pexp_desc =
              Pexp_apply (pipe, [ (Nolabel, replacement); (Nolabel, right) ]);
          }
        in
        A.pexp_let ~loc:call.pexp_loc Nonrecursive [ binding ] call
        |> add_layer_type_attribute descriptor ~id
        |> add_evidence_attribute ~name:owner_attribute ~id
        |> add_evidence_attribute ~name:layer_forwarding_attribute ~id
      else
        let call =
          add_evidence_attribute ~name:owner_attribute ~id call
          |> add_layer_type_attribute descriptor ~id
        in
        {
          call with
          pexp_desc = Pexp_apply (pipe, [ (Nolabel, left); (Nolabel, right) ]);
        }

let isolate_candidate candidate marker =
  let kind = candidate_kind candidate in
  let upstream = candidate_upstream candidate in
  let loc = (candidate_call candidate).pexp_loc in
  let digest = Digest.to_hex (Digest.string marker.id) in
  let binding_name = "_hamlet_subtractor_upstream_" ^ digest in
  let pattern = A.ppat_var ~loc:upstream.pexp_loc { txt = binding_name; loc } in
  let marked_upstream =
    add_upstream_attribute ~kind ~id:marker.id upstream
    |> add_layer_type_attribute (candidate_descriptor candidate) ~id:marker.id
  in
  let binding =
    A.value_binding ~loc ~pat:pattern ~expr:marked_upstream
    |> add_value_binding_attribute ~name:generic_output_link_attribute
         ~id:marker.id
  in
  let replacement =
    A.pexp_ident ~loc:upstream.pexp_loc
      { txt = Lident binding_name; loc = upstream.pexp_loc }
  in
  let handler = candidate_handler candidate in
  let handler_binding_name = "_hamlet_subtractor_handler_" ^ digest in
  let handler_pattern =
    A.ppat_var ~loc:handler.pexp_loc
      { txt = handler_binding_name; loc = handler.pexp_loc }
  in
  let marked_handler =
    add_evidence_attribute ~name:handler_attribute ~id:marker.id handler
  in
  let handler_binding =
    A.value_binding ~loc:handler.pexp_loc ~pat:handler_pattern
      ~expr:marked_handler
  in
  let probe_handler =
    let body =
      A.pexp_assert ~loc:handler.pexp_loc (A.ebool ~loc:handler.pexp_loc false)
    in
    let rec parameters remaining body =
      if remaining = 0 then body
      else
        A.pexp_fun ~loc:handler.pexp_loc Nolabel None
          (A.ppat_any ~loc:handler.pexp_loc)
          (parameters (remaining - 1) body)
    in
    parameters ((candidate_descriptor candidate).handler_peel + 1) body
  in
  let call = candidate_call candidate in
  let call_without_outer_attributes = { call with pexp_attributes = [] } in
  let isolated_call =
    match candidate with
    | Direct_candidate { callee; args; upstream_index; _ } ->
        let callee =
          add_evidence_attribute ~name:callee_attribute ~id:marker.id callee
        in
        let args =
          List.map
            (fun (label, argument) ->
              match label with
              | Labelled actual
                when String.equal actual
                       (candidate_descriptor candidate).handler_label ->
                  (label, probe_handler)
              | Labelled actual
                when Option.equal String.equal
                       (candidate_descriptor candidate).required_label
                       (Some actual) ->
                  ( label,
                    add_evidence_attribute ~name:contributor_attribute
                      ~id:marker.id argument )
              | Nolabel | Optional _ | Labelled _ -> (label, argument))
            args
        in
        {
          call_without_outer_attributes with
          pexp_desc =
            Pexp_apply
              (callee, replace_direct_upstream upstream_index replacement args);
        }
    | Pipe_candidate { pipe; right; _ } ->
        let right =
          match right.pexp_desc with
          | Pexp_apply (callee, args) ->
              let callee =
                add_evidence_attribute ~name:callee_attribute ~id:marker.id
                  callee
              in
              let args =
                List.map
                  (fun (label, argument) ->
                    match label with
                    | Labelled actual
                      when String.equal actual
                             (candidate_descriptor candidate).handler_label ->
                        (label, probe_handler)
                    | Labelled actual
                      when Option.equal String.equal
                             (candidate_descriptor candidate).required_label
                             (Some actual) ->
                        ( label,
                          add_evidence_attribute ~name:contributor_attribute
                            ~id:marker.id argument )
                    | Nolabel | Optional _ | Labelled _ -> (label, argument))
                  args
              in
              { right with pexp_desc = Pexp_apply (callee, args) }
          | _ -> right
        in
        {
          call_without_outer_attributes with
          pexp_desc =
            Pexp_apply (pipe, [ (Nolabel, replacement); (Nolabel, right) ]);
        }
  in
  let isolated_call =
    A.pexp_let ~loc Nonrecursive [ handler_binding ] isolated_call
  in
  { call with pexp_desc = Pexp_let (Nonrecursive, [ binding ], isolated_call) }
  |> add_layer_type_attribute (candidate_descriptor candidate) ~id:marker.id
  |> add_evidence_attribute ~name:owner_attribute ~id:marker.id

let prepare structure =
  let base_structure, markers = canonicalize_markers structure in
  let by_id = Hashtbl.create (List.length markers) in
  List.iter (fun marker -> Hashtbl.replace by_id marker.id marker) markers;
  let claimed = Hashtbl.create (List.length markers) in
  let owners = ref [] in
  let refusals = ref (named_handler_refusals markers base_structure) in
  List.iter
    (fun (refusal : refusal) -> Hashtbl.replace claimed refusal.marker.id ())
    !refusals;
  let claim_refusal id reason loc =
    match Hashtbl.find_opt by_id id with
    | None -> ()
    | Some marker ->
        Hashtbl.replace claimed id ();
        refusals := { marker; reason; loc } :: !refusals
  in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        let expression = super#expression expression in
        match candidate_status expression with
        | Candidate candidate -> (
            let handler = candidate_handler candidate in
            let marker_ids =
              markers_in_expression handler
              |> List.filter (fun id -> not (Hashtbl.mem claimed id))
            in
            if marker_ids = [] then expression
            else if not (inline_handler handler) then (
              List.iter
                (fun id ->
                  claim_refusal id Unsupported_call_shape handler.pexp_loc)
                marker_ids;
              expression)
            else
              match marker_ids with
              | [ id ] -> (
                  match Hashtbl.find_opt by_id id with
                  | None -> expression
                  | Some (marker : marker)
                    when marker.kind <> candidate_kind candidate ->
                      claim_refusal id
                        (Wrong_channel
                           {
                             owner = candidate_kind candidate;
                             marker = marker.kind;
                           })
                        marker.loc;
                      expression
                  | Some marker ->
                      Hashtbl.replace claimed id ();
                      owners :=
                        {
                          marker;
                          form = candidate_form candidate;
                          call_loc = (candidate_call candidate).pexp_loc;
                          upstream_loc = (candidate_upstream candidate).pexp_loc;
                          handler_loc = handler.pexp_loc;
                        }
                        :: !owners;
                      isolate_candidate candidate marker)
              | ids ->
                  List.iter
                    (fun id ->
                      claim_refusal id Ambiguous_owner handler.pexp_loc)
                    ids;
                  expression)
        | Unsupported_candidate _ ->
            markers_in_expression expression
            |> List.filter (fun id -> not (Hashtbl.mem claimed id))
            |> List.iter (fun id ->
                claim_refusal id Unsupported_call_shape expression.pexp_loc);
            expression
        | Partial_candidate | Not_candidate -> expression
    end
  in
  let probe_structure = mapper#structure base_structure in
  List.iter
    (fun (marker : marker) ->
      if not (Hashtbl.mem claimed marker.id) then
        refusals :=
          { marker; reason = No_supported_owner; loc = marker.loc } :: !refusals)
    markers;
  let owners = List.rev !owners in
  let base_claimed = Hashtbl.create (List.length owners) in
  let base_mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        let expression = super#expression expression in
        match candidate_status expression with
        | Candidate candidate -> (
            let owned_markers =
              markers_in_expression (candidate_handler candidate)
              |> List.filter (fun id ->
                  (not (Hashtbl.mem base_claimed id))
                  && List.exists
                       (fun (owner : owner) -> String.equal owner.marker.id id)
                       owners)
            in
            match owned_markers with
            | [ id ] ->
                Hashtbl.replace base_claimed id ();
                begin match
                  List.find_opt
                    (fun (owner : owner) -> String.equal owner.marker.id id)
                    owners
                with
                | Some (owner : owner) ->
                    mark_base_candidate candidate owner.marker
                | None -> expression
                end
            | [] | _ :: _ :: _ -> expression)
        | Partial_candidate | Unsupported_candidate _ | Not_candidate ->
            expression
    end
  in
  let base_structure = base_mapper#structure base_structure in
  {
    base_structure;
    probe_structure;
    structure = probe_structure;
    markers;
    owners;
    refusals = List.rev !refusals;
  }

type variant_row = { labels : string list; closed : bool; fixed : bool }

type normalized_type =
  | Variable
  | Variant of variant_row
  | Constructor of string * normalized_type list
  | Other

type typed_observation = {
  id : string;
  kind : propagation_kind;
  upstream_type : normalized_type;
  marker_type : normalized_type;
}

type lookup_error =
  | Missing_upstream of string
  | Missing_marker of string
  | Duplicate_upstream of string
  | Duplicate_marker of string
  | Invalid_marker_id of string

let compiler_string_payload (payload : Compiler_parsetree.payload) =
  match payload with
  | Compiler_parsetree.PStr
      [
        {
          pstr_desc =
            Compiler_parsetree.Pstr_eval
              ( {
                  pexp_desc =
                    Compiler_parsetree.Pexp_constant
                      {
                        pconst_desc =
                          Compiler_parsetree.Pconst_string (value, _, _);
                        _;
                      };
                  _;
                },
                _ );
          _;
        };
      ] ->
      Some value
  | _ -> None

let compiler_attribute_values name attributes =
  List.filter_map
    (fun (attribute : Compiler_parsetree.attribute) ->
      if String.equal attribute.attr_name.txt name then
        compiler_string_payload attribute.attr_payload
      else None)
    attributes

let add_expression table id expression =
  let expressions = Option.value (Hashtbl.find_opt table id) ~default:[] in
  Hashtbl.replace table id (expression :: expressions)

let rec normalize_type type_expression =
  match Compiler_types.get_desc type_expression with
  | Compiler_types.Tvar _ | Compiler_types.Tunivar _ -> Variable
  | Compiler_types.Tvariant row ->
      let labels =
        Compiler_types.row_fields row
        |> List.filter_map (fun (label, field) ->
            match Compiler_types.row_field_repr field with
            | Compiler_types.Rabsent -> None
            | Compiler_types.Rpresent _ | Compiler_types.Reither _ -> Some label)
        |> List.sort_uniq String.compare
      in
      Variant
        {
          labels;
          closed = Compiler_types.row_closed row;
          fixed = Option.is_some (Compiler_types.row_fixed row);
        }
  | Compiler_types.Tconstr (path, arguments, _) ->
      Constructor (Compiler_path.name path, List.map normalize_type arguments)
  | Compiler_types.Tpoly (body, _) -> normalize_type body
  | Compiler_types.Tlink linked | Compiler_types.Tsubst (linked, _) ->
      normalize_type linked
  | Compiler_types.Tarrow _ | Compiler_types.Ttuple _ | Compiler_types.Tobject _
  | Compiler_types.Tfield _ | Compiler_types.Tnil | Compiler_types.Tpackage _
  | Compiler_types.Tfunctor _ ->
      Other

let observe_typedtree structure =
  let upstreams = Hashtbl.create 16 in
  let markers = Hashtbl.create 16 in
  let iterator =
    let default = Compiler_tast_iterator.default_iterator in
    {
      default with
      expr =
        (fun self expression ->
          compiler_attribute_values upstream_attribute expression.exp_attributes
          |> List.iter (fun id -> add_expression upstreams id expression);
          compiler_attribute_values marker_attribute expression.exp_attributes
          |> List.iter (fun id -> add_expression markers id expression);
          default.expr self expression);
    }
  in
  iterator.structure iterator structure;
  let ids = Hashtbl.create 16 in
  Hashtbl.iter (fun id _ -> Hashtbl.replace ids id ()) upstreams;
  let links = ref [] in
  let errors = ref [] in
  Hashtbl.iter
    (fun id () ->
      match
        ( propagation_kind_of_id id,
          Hashtbl.find_opt upstreams id,
          Hashtbl.find_opt markers id )
      with
      | None, _, _ -> errors := Invalid_marker_id id :: !errors
      | Some _, None, _ -> errors := Missing_upstream id :: !errors
      | Some _, _, None -> errors := Missing_marker id :: !errors
      | Some _, Some (_ :: _ :: _), _ ->
          errors := Duplicate_upstream id :: !errors
      | Some _, _, Some (_ :: _ :: _) ->
          errors := Duplicate_marker id :: !errors
      | ( Some kind,
          Some [ (upstream_rhs : Compiler_typedtree.expression) ],
          Some [ (marker_expr : Compiler_typedtree.expression) ] ) ->
          links :=
            {
              id;
              kind;
              upstream_type = normalize_type upstream_rhs.exp_type;
              marker_type = normalize_type marker_expr.exp_type;
            }
            :: !links
      | Some _, Some [], _ -> errors := Missing_upstream id :: !errors
      | Some _, _, Some [] -> errors := Missing_marker id :: !errors)
    ids;
  match !errors with
  | [] ->
      Ok
        (List.sort
           (fun (left : typed_observation) (right : typed_observation) ->
             String.compare left.id right.id)
           !links)
  | errors -> Error (List.rev errors)
