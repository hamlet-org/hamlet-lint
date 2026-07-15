open Ppxlib
module A = Ast_builder.Default

let extension_name = "hamlet.forward.auto"
let call_attribute = "hamlet.subtractor.generic_call.v1"
let callee_attribute = "hamlet.subtractor.generic_callee.v1"
let source_attribute = "hamlet.subtractor.generic_source.v1"
let placeholder_attribute = "hamlet.subtractor.generic_placeholder.v1"

type call = {
  id : string;
  loc : Location.t;
  callee_loc : Location.t;
  source_loc : Location.t;
  placeholder_loc : Location.t;
}

type refusal_reason =
  | Not_a_final_argument
  | Labelled_argument
  | Missing_effect_argument
  | Multiple_placeholders
  | Pipeline_application

type refusal = { loc : Location.t; reason : refusal_reason }

type prepared = {
  base_structure : structure;
  probe_structure : structure;
  calls : call list;
  refusals : refusal list;
}

let refusal_message = function
  | Not_a_final_argument ->
      "[%hamlet.forward.auto] must be the final argument of a direct helper \
       call"
  | Labelled_argument ->
      "[%hamlet.forward.auto] must be an unlabelled final argument"
  | Missing_effect_argument ->
      "the generic helper call has no concrete effect argument before \
       [%hamlet.forward.auto]"
  | Multiple_placeholders ->
      "one generic helper call accepts exactly one [%hamlet.forward.auto] \
       argument"
  | Pipeline_application ->
      "generic helper specialization does not support ambiguous pipeline \
       application; call the helper directly"

let string_payload value =
  PStr
    [ A.pstr_eval ~loc:Location.none (A.estring ~loc:Location.none value) [] ]

let attribute ~name ~value =
  {
    attr_name = { txt = name; loc = Location.none };
    attr_payload = string_payload value;
    attr_loc = Location.none;
  }

let add_attribute ~name ~value expression =
  {
    expression with
    pexp_attributes = attribute ~name ~value :: expression.pexp_attributes;
  }

let extension = function
  | { pexp_desc = Pexp_extension ({ txt; _ }, PStr []); _ }
    when String.equal txt extension_name ->
      true
  | _ -> false

let has_extension expression =
  let found = ref false in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        if extension expression then found := true
        else super#expression expression
    end
  in
  iterator#expression expression;
  !found

let location_key loc =
  (loc.loc_start.pos_fname, loc.loc_start.pos_cnum, loc.loc_end.pos_cnum)

let claim_extensions claimed expression =
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        if extension expression then
          Hashtbl.replace claimed (location_key expression.pexp_loc) ();
        super#expression expression
    end
  in
  iterator#expression expression

let is_pipe = function
  | { pexp_desc = Pexp_ident { txt = Lident "|>"; _ }; _ } -> true
  | _ -> false

let call_id ~structure_digest ~loc ~ordinal =
  let digest =
    String.concat "\000"
      [
        structure_digest;
        loc.loc_start.pos_fname;
        string_of_int loc.loc_start.pos_cnum;
        string_of_int loc.loc_end.pos_cnum;
        string_of_int ordinal;
      ]
    |> Digest.string
    |> Digest.to_hex
  in
  Printf.sprintf "generic-call:%s:%d" digest ordinal

let prepare structure =
  let structure_digest =
    Marshal.to_string structure [ Marshal.No_sharing ]
    |> Digest.string
    |> Digest.to_hex
  in
  let ordinal = ref 0 in
  let calls = ref [] in
  let refusals = ref [] in
  let claimed = Hashtbl.create 16 in
  let mapper =
    object (self)
      inherit Ast_traverse.map as super

      method private reject expression reason =
        claim_extensions claimed expression;
        refusals := { loc = expression.pexp_loc; reason } :: !refusals;
        expression

      method! expression expression =
        match expression.pexp_desc with
        | Pexp_apply (pipe, [ (Nolabel, _); (Nolabel, right) ])
          when is_pipe pipe && has_extension right ->
            self#reject expression Pipeline_application
        | Pexp_apply (callee, arguments) -> (
            let placeholder_count =
              List.fold_left
                (fun count (_, argument) ->
                  if has_extension argument then count + 1 else count)
                0 arguments
            in
            if placeholder_count = 0 then super#expression expression
            else if placeholder_count > 1 then
              self#reject expression Multiple_placeholders
            else
              match List.rev arguments with
              | (label, placeholder) :: reversed_arguments
                when extension placeholder -> (
                  let arguments = List.rev reversed_arguments in
                  if label <> Nolabel then
                    self#reject placeholder Labelled_argument
                  else
                    match List.rev arguments with
                    | (Nolabel, source) :: _ ->
                        let id =
                          call_id ~structure_digest ~loc:expression.pexp_loc
                            ~ordinal:!ordinal
                        in
                        incr ordinal;
                        Hashtbl.replace claimed
                          (location_key placeholder.pexp_loc)
                          ();
                        let placeholder =
                          A.pexp_assert ~loc:placeholder.pexp_loc
                            (A.ebool ~loc:placeholder.pexp_loc false)
                          |> add_attribute ~name:placeholder_attribute ~value:id
                        in
                        let callee =
                          super#expression callee
                          |> add_attribute ~name:callee_attribute ~value:id
                        in
                        let arguments =
                          List.map
                            (fun (argument_label, argument) ->
                              let argument = super#expression argument in
                              if
                                argument_label = Nolabel
                                && Location.compare argument.pexp_loc
                                     source.pexp_loc
                                   = 0
                              then
                                ( argument_label,
                                  add_attribute ~name:source_attribute ~value:id
                                    argument )
                              else (argument_label, argument))
                            arguments
                        in
                        calls :=
                          {
                            id;
                            loc = expression.pexp_loc;
                            callee_loc = callee.pexp_loc;
                            source_loc = source.pexp_loc;
                            placeholder_loc = placeholder.pexp_loc;
                          }
                          :: !calls;
                        {
                          expression with
                          pexp_desc =
                            Pexp_apply
                              (callee, arguments @ [ (Nolabel, placeholder) ]);
                        }
                        |> add_attribute ~name:call_attribute ~value:id
                    | _ -> self#reject expression Missing_effect_argument)
              | _ -> self#reject expression Not_a_final_argument)
        | _ -> super#expression expression
    end
  in
  let probe_structure = mapper#structure structure in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        (if extension expression then
           let key = location_key expression.pexp_loc in
           if not (Hashtbl.mem claimed key) then
             refusals :=
               { loc = expression.pexp_loc; reason = Not_a_final_argument }
               :: !refusals);
        super#expression expression
    end
  in
  iterator#structure structure;
  {
    base_structure = structure;
    probe_structure;
    calls = List.rev !calls;
    refusals = List.rev !refusals;
  }

let expectations prepared =
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | call :: rest -> (
        match
          Hamlet_subtractor_core.Protocol.generic_expectation ~id:call.id
            ~kind:Hamlet_subtractor_core.Protocol.Call
        with
        | Ok expectation -> loop (expectation :: accumulated) rest
        | Error _ ->
            Error ("invalid generic call attachment identity " ^ call.id))
  in
  loop [] prepared.calls

type finalization_error =
  | Missing_attachment of string
  | Duplicate_attachment of string
  | Invalid_attachment of string
  | Contract_evaluation_failed of string
  | Generation_failed of Hamlet_subtractor_generator.error
  | Missing_placeholder of string
  | Duplicate_placeholder of string

let finalization_error_message = function
  | Missing_attachment id -> "missing generic call evidence for " ^ id
  | Duplicate_attachment id -> "duplicate generic call evidence for " ^ id
  | Invalid_attachment id -> "invalid generic call evidence for " ^ id
  | Contract_evaluation_failed id ->
      "generic helper contract cannot be instantiated for " ^ id
  | Generation_failed error -> Hamlet_subtractor_generator.error_message error
  | Missing_placeholder id ->
      "final AST no longer contains [%hamlet.forward.auto] for " ^ id
  | Duplicate_placeholder id ->
      "final AST contains duplicate [%hamlet.forward.auto] for " ^ id

let attachment_for_call attachments id =
  let module Protocol = Hamlet_subtractor_core.Protocol in
  attachments
  |> List.filter (fun attachment ->
      String.equal id (Protocol.generic_attachment_id attachment)
      && Protocol.generic_attachment_kind attachment = Protocol.Call)
  |> function
  | [ attachment ] -> Ok attachment
  | [] -> Error (Missing_attachment id)
  | _ -> Error (Duplicate_attachment id)

let expression_for_call ~catalogues ~loc attachments call =
  let module Core = Hamlet_subtractor_core in
  match attachment_for_call attachments call.id with
  | Error _ as error -> error
  | Ok attachment -> (
      match
        Core.Generic_resolution.decode_call
          (Core.Protocol.generic_attachment_payload attachment)
      with
      | Error _ -> Error (Invalid_attachment call.id)
      | Ok (contract, input) -> (
          match Core.Generic_contract.instantiate_slots ~input contract with
          | Error _ -> Error (Contract_evaluation_failed call.id)
          | Ok instantiated ->
              let rec generate accumulated = function
                | [] ->
                    Ok
                      (Hamlet_subtractor_generic_generator.bundle ~loc
                         (List.rev accumulated))
                | current :: rest ->
                    let slot =
                      Core.Generic_contract.instantiated_slot current
                    in
                    let residual =
                      Core.Generic_contract.instantiated_residual current
                    in
                    begin match
                      Hamlet_subtractor_generic_generator.slot ~loc ~catalogues
                        ~input:(Core.Residual.input residual)
                        ~claimed:(Core.Generic_contract.slot_claimed slot)
                    with
                    | Error error -> Error (Generation_failed error)
                    | Ok expression -> generate (expression :: accumulated) rest
                    end
              in
              generate [] instantiated))

let same_location left right =
  String.equal left.loc_start.pos_fname right.loc_start.pos_fname
  && left.loc_start.pos_cnum = right.loc_start.pos_cnum
  && left.loc_end.pos_cnum = right.loc_end.pos_cnum

let finalize ~calls ~attachments ~catalogues structure =
  let counts = Hashtbl.create (List.length calls) in
  let error = ref None in
  let call_at loc =
    List.find_opt (fun call -> same_location call.placeholder_loc loc) calls
  in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        match (extension expression, call_at expression.pexp_loc) with
        | true, Some call ->
            let count =
              Option.value (Hashtbl.find_opt counts call.id) ~default:0
            in
            Hashtbl.replace counts call.id (count + 1);
            begin match
              expression_for_call ~catalogues ~loc:expression.pexp_loc
                attachments call
            with
            | Ok expression -> expression
            | Error finalization_error ->
                error := Some finalization_error;
                expression
            end
        | true, None -> super#expression expression
        | false, _ -> super#expression expression
    end
  in
  let structure = mapper#structure structure in
  match !error with
  | Some error -> Error error
  | None ->
      let missing_or_duplicate =
        List.find_map
          (fun call ->
            match Option.value (Hashtbl.find_opt counts call.id) ~default:0 with
            | 0 -> Some (Missing_placeholder call.id)
            | 1 -> None
            | _ -> Some (Duplicate_placeholder call.id))
          calls
      in
      begin match missing_or_duplicate with
      | Some error -> Error error
      | None -> Ok structure
      end
