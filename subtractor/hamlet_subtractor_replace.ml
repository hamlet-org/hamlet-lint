open Ppxlib
open Hamlet_subtractor_core

type error =
  | Missing_outcome of string
  | Missing_certificate of Marker.id
  | Missing_owner of Marker.id
  | Duplicate_owner of Marker.id
  | Missing_upstream of Marker.id
  | Duplicate_upstream of Marker.id
  | Missing_marker_case of Marker.id
  | Duplicate_marker_case of Marker.id
  | Refused of Diagnostic.t
  | Generation_failed of Marker.t * Hamlet_subtractor_generator.error
  | Unmaterializable_certificate of Marker.t * Leaf.t

let error_message = function
  | Missing_outcome id -> "missing resolver outcome for marker " ^ id
  | Missing_certificate id ->
      "missing exact effect certificate for marker " ^ Marker.id_to_string id
  | Missing_owner id ->
      "final AST no longer contains the owner for marker "
      ^ Marker.id_to_string id
  | Duplicate_owner id ->
      "final AST contains more than one owner for marker "
      ^ Marker.id_to_string id
  | Missing_upstream id ->
      "final AST no longer contains the upstream effect for marker "
      ^ Marker.id_to_string id
  | Duplicate_upstream id ->
      "final AST contains more than one upstream effect for marker "
      ^ Marker.id_to_string id
  | Missing_marker_case id ->
      "final AST no longer contains marker " ^ Marker.id_to_string id
  | Duplicate_marker_case id ->
      "final AST contains duplicate marker " ^ Marker.id_to_string id
  | Refused diagnostic -> Diagnostic.message diagnostic
  | Generation_failed (_, error) ->
      Hamlet_subtractor_generator.error_message error
  | Unmaterializable_certificate (_, leaf) ->
      Printf.sprintf "exact effect certificate leaf %s has no source type"
        (leaf |> Leaf.identity |> Identity.to_string)

let marker_attribute = "hamlet.subtractor.marker.v1"
let upstream_attribute = "hamlet.subtractor.upstream.v1"
let callee_attribute = "hamlet.subtractor.callee.v1"
let handler_attribute = "hamlet.subtractor.handler.v1"
let owner_attribute = "hamlet.subtractor.owner.v1"

let is_probe_attribute attribute =
  String.equal attribute.attr_name.txt marker_attribute
  || String.equal attribute.attr_name.txt upstream_attribute
  || String.equal attribute.attr_name.txt callee_attribute
  || String.equal attribute.attr_name.txt handler_attribute
  || String.equal attribute.attr_name.txt owner_attribute

let remove_probe_attributes attributes =
  List.filter (fun attribute -> not (is_probe_attribute attribute)) attributes

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

let marker_ids expression =
  List.filter_map
    (fun attribute ->
      if String.equal attribute.attr_name.txt marker_attribute then
        string_payload attribute.attr_payload
      else None)
    expression.pexp_attributes

let owner_ids expression =
  List.filter_map
    (fun attribute ->
      if String.equal attribute.attr_name.txt owner_attribute then
        string_payload attribute.attr_payload
      else None)
    expression.pexp_attributes

let upstream_ids expression =
  List.filter_map
    (fun attribute ->
      if String.equal attribute.attr_name.txt upstream_attribute then
        string_payload attribute.attr_payload
      else None)
    expression.pexp_attributes

let find_outcome outcomes id =
  List.find_opt
    (fun (marker, _) ->
      String.equal id (Marker.id_to_string (Marker.id marker)))
    outcomes

let find_resolved
    (resolved_values : (Marker.t * Hamlet_subtractor_engine.resolved) list)
    id =
  List.find_opt
    (fun (marker, _) ->
      String.equal id (Marker.id_to_string (Marker.id marker)))
    resolved_values

let longident = function
  | [] -> invalid_arg "Hamlet_subtractor_replace.longident"
  | [ name ] -> Longident.Lident name
  | head :: tail ->
      List.fold_left
        (fun path name -> Longident.Ldot (path, name))
        (Longident.Lident head) tail

let identity_lid identity =
  longident
    (Identity.module_path identity @ [ Identity.declaration_name identity ])

let primitive_lid (primitive : Type_identity.primitive) =
  match primitive with
  | Type_identity.Unit -> Longident.Lident "unit"
  | Type_identity.Bool -> Lident "bool"
  | Type_identity.Char -> Lident "char"
  | Type_identity.Int -> Lident "int"
  | Type_identity.Int32 -> Lident "int32"
  | Type_identity.Int64 -> Lident "int64"
  | Type_identity.Nativeint -> Lident "nativeint"
  | Type_identity.Float -> Lident "float"
  | Type_identity.String -> Lident "string"
  | Type_identity.Bytes -> Lident "bytes"

let rec materialize_type_identity ~loc identity =
  match Type_identity.view identity with
  | Type_identity.Primitive primitive ->
      Ast_builder.Default.ptyp_constr ~loc
        { txt = primitive_lid primitive; loc }
        []
  | Type_identity.Tuple elements ->
      Ast_builder.Default.ptyp_tuple ~loc
        (List.map (materialize_type_identity ~loc) elements)
  | Type_identity.Nominal { declaration; arguments } ->
      Ast_builder.Default.ptyp_constr ~loc
        { txt = identity_lid declaration; loc }
        (List.map (materialize_type_identity ~loc) arguments)

let inherited_row_field ~loc identity =
  {
    prf_desc =
      Rinherit
        (Ast_builder.Default.ptyp_constr ~loc
           { txt = identity_lid identity; loc }
           []);
    prf_loc = loc;
    prf_attributes = [];
  }

let structural_row_field ~loc atom =
  let constant, payloads =
    match Atom.payload atom with
    | Atom.No_payload -> (true, [])
    | Atom.Payload payload -> (false, [ materialize_type_identity ~loc payload ])
  in
  {
    prf_desc = Rtag ({ txt = Atom.label atom; loc }, constant, payloads);
    prf_loc = loc;
    prf_attributes = [];
  }

let materialize_leaf ~loc leaf =
  match Leaf.materialization leaf with
  | Leaf.Direct | Leaf.Error_cases _ | Leaf.Requirement_tag ->
      Ok (inherited_row_field ~loc (Leaf.identity leaf))
  | Leaf.Structural_variant -> (
      match Leaf.members leaf with
      | [ atom ] -> Ok (structural_row_field ~loc atom)
      | [] | _ :: _ :: _ -> Error leaf)
  | Leaf.Unavailable _ -> Error leaf

let materialize_proof ~loc proof =
  match Proof.leaves proof with
  | [] ->
      Ok
        (Ast_builder.Default.ptyp_constr ~loc
           { txt = Longident.Ldot (Lident "Hamlet", "never"); loc }
           [])
  | leaves ->
      let rec loop fields = function
        | [] ->
            Ok
              (Ast_builder.Default.ptyp_variant ~loc (List.rev fields) Closed
                 None)
        | leaf :: rest -> (
            match materialize_leaf ~loc leaf with
            | Ok field -> loop (field :: fields) rest
            | Error _ as error -> error)
      in
      loop [] leaves

let materialize_evidence ~loc evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Opaque_reasons _ ->
      Ok (Ast_builder.Default.ptyp_any ~loc)
  | Effect_certificate.Exact_proof proof -> materialize_proof ~loc proof

let materialize_certificate ~loc certificate =
  match materialize_evidence ~loc (Effect_certificate.errors certificate) with
  | Error _ as error -> error
  | Ok errors -> (
      match
        materialize_evidence ~loc (Effect_certificate.requirements certificate)
      with
      | Error _ as error -> error
      | Ok requirements ->
          Ok
            (Ast_builder.Default.ptyp_constr ~loc
               { txt = Longident.Ldot (Lident "Hamlet", "t"); loc }
               [ Ast_builder.Default.ptyp_any ~loc; errors; requirements ]))

let source_certificate marker (resolved : Hamlet_subtractor_engine.resolved) =
  let target =
    resolved.Hamlet_subtractor_engine.residual
    |> Residual.input
    |> Effect_certificate.exact
  in
  let errors, requirements =
    match Marker.kind marker with
    | Kind.Error ->
        (target, Effect_certificate.requirements resolved.certificate)
    | Kind.Requirement ->
        (Effect_certificate.errors resolved.certificate, target)
  in
  Effect_certificate.create ~errors ~requirements |> function
  | Ok certificate -> certificate
  | Error _ -> assert false

exception Replacement_error of error

let strip_probe_attributes input =
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! attributes attributes =
        remove_probe_attributes attributes |> super#attributes
    end
  in
  mapper#structure input

let structure ~catalogues ~outcomes ~resolved_values input =
  let counts = Hashtbl.create (List.length outcomes) in
  let owner_counts = Hashtbl.create (List.length outcomes) in
  let upstream_counts = Hashtbl.create (List.length outcomes) in
  let claim_owner id =
    match find_outcome outcomes id with
    | None -> raise (Replacement_error (Missing_outcome id))
    | Some (marker, _) ->
        let count =
          Option.value (Hashtbl.find_opt owner_counts id) ~default:0
        in
        Hashtbl.replace owner_counts id (count + 1);
        if count <> 0 then
          raise (Replacement_error (Duplicate_owner (Marker.id marker)));
        marker
  in
  let replace_case self case =
    match marker_ids case.pc_rhs with
    | [] -> [ self#case case ]
    | [ id ] -> (
        match find_outcome outcomes id with
        | None -> raise (Replacement_error (Missing_outcome id))
        | Some (_marker, Protocol.Refused diagnostic) ->
            raise (Replacement_error (Refused diagnostic))
        | Some (marker, Protocol.Resolved residual) ->
            let count = Option.value (Hashtbl.find_opt counts id) ~default:0 in
            Hashtbl.replace counts id (count + 1);
            if count <> 0 then
              raise
                (Replacement_error (Duplicate_marker_case (Marker.id marker)));
            begin match
              Hamlet_subtractor_generator.cases ~loc:case.pc_lhs.ppat_loc
                ~catalogues residual
            with
            | Ok cases -> cases
            | Error error ->
                raise (Replacement_error (Generation_failed (marker, error)))
            end)
    | _ -> raise (Replacement_error (Missing_outcome "duplicate marker attrs"))
  in
  let constrain_upstream id expression =
    match find_resolved resolved_values id with
    | None -> (
        match find_outcome outcomes id with
        | Some (_, Protocol.Refused diagnostic) ->
            raise (Replacement_error (Refused diagnostic))
        | Some (marker, _) ->
            raise (Replacement_error (Missing_certificate (Marker.id marker)))
        | None -> raise (Replacement_error (Missing_outcome id)))
    | Some (marker, resolved) ->
        let count =
          Option.value (Hashtbl.find_opt upstream_counts id) ~default:0
        in
        Hashtbl.replace upstream_counts id (count + 1);
        if count <> 0 then
          raise (Replacement_error (Duplicate_upstream (Marker.id marker)));
        let loc = { expression.pexp_loc with loc_ghost = true } in
        begin match
          materialize_certificate ~loc (source_certificate marker resolved)
        with
        | Error leaf ->
            raise
              (Replacement_error (Unmaterializable_certificate (marker, leaf)))
        | Ok type_ ->
            let inner =
              {
                expression with
                pexp_loc = loc;
                pexp_loc_stack = [];
                pexp_attributes = [];
              }
            in
            {
              expression with
              pexp_desc = Pexp_constraint (inner, type_);
              pexp_attributes = expression.pexp_attributes;
            }
        end
  in
  let mapper =
    object (self)
      inherit Ast_traverse.map as super

      method! expression expression =
        let owner_ids = owner_ids expression in
        let marker_ids = marker_ids expression in
        let upstream_ids = upstream_ids expression in
        let expression =
          {
            expression with
            pexp_attributes = remove_probe_attributes expression.pexp_attributes;
          }
        in
        let expression =
          match expression.pexp_desc with
          | Pexp_match (scrutinee, cases) ->
              {
                expression with
                pexp_desc =
                  Pexp_match
                    ( self#expression scrutinee,
                      List.concat_map (replace_case self) cases );
              }
          | Pexp_function
              (parameters, constraint_, Pfunction_cases (cases, loc, attrs)) ->
              {
                expression with
                pexp_desc =
                  Pexp_function
                    ( List.map self#function_param parameters,
                      Option.map self#type_constraint constraint_,
                      Pfunction_cases
                        ( List.concat_map (replace_case self) cases,
                          loc,
                          self#attributes attrs ) );
              }
          | _ -> super#expression expression
        in
        let expression =
          match upstream_ids with
          | [] -> expression
          | [ id ] -> constrain_upstream id expression
          | _ ->
              raise
                (Replacement_error (Missing_outcome "duplicate upstream attrs"))
        in
        match (owner_ids, marker_ids) with
        | [], _ | _, _ :: _ -> expression
        | [ id ], [] -> (
            let owner_marker = claim_owner id in
            match find_resolved resolved_values id with
            | None -> (
                match find_outcome outcomes id with
                | Some (_, Protocol.Refused diagnostic) ->
                    raise (Replacement_error (Refused diagnostic))
                | Some _ ->
                    raise
                      (Replacement_error
                         (Missing_certificate (Marker.id owner_marker)))
                | None -> raise (Replacement_error (Missing_outcome id)))
            | Some (marker, resolved) ->
                let loc = { expression.pexp_loc with loc_ghost = true } in
                begin match
                  materialize_certificate ~loc resolved.certificate
                with
                | Error leaf ->
                    raise
                      (Replacement_error
                         (Unmaterializable_certificate (marker, leaf)))
                | Ok type_ ->
                    let inner =
                      { expression with pexp_loc = loc; pexp_loc_stack = [] }
                    in
                    {
                      expression with
                      pexp_desc = Pexp_constraint (inner, type_);
                      pexp_attributes = [];
                    }
                end)
        | id :: _ :: _, [] ->
            let marker = claim_owner id in
            raise (Replacement_error (Duplicate_owner (Marker.id marker)))
    end
  in
  try
    let output = mapper#structure input |> strip_probe_attributes in
    match
      List.find_opt
        (fun (marker, _) ->
          let id = Marker.id_to_string (Marker.id marker) in
          Option.value (Hashtbl.find_opt counts id) ~default:0 = 0)
        outcomes
    with
    | Some (marker, _) -> Error (Missing_marker_case (Marker.id marker))
    | None -> (
        match
          List.find_opt
            (fun (marker, outcome) ->
              match outcome with
              | Protocol.Refused _ -> false
              | Protocol.Resolved _ ->
                  let id = Marker.id_to_string (Marker.id marker) in
                  Option.value (Hashtbl.find_opt owner_counts id) ~default:0 = 0)
            outcomes
        with
        | Some (marker, _) -> Error (Missing_owner (Marker.id marker))
        | None -> (
            match
              List.find_opt
                (fun (marker, outcome) ->
                  match outcome with
                  | Protocol.Refused _ -> false
                  | Protocol.Resolved _ ->
                      let id = Marker.id_to_string (Marker.id marker) in
                      Option.value
                        (Hashtbl.find_opt upstream_counts id)
                        ~default:0
                      = 0)
                outcomes
            with
            | Some (marker, _) -> Error (Missing_upstream (Marker.id marker))
            | None -> Ok output))
  with Replacement_error error -> Error error
