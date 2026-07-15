open Ppxlib
module A = Ast_builder.Default

let legacy_extension_name = "hamlet.forward.auto"
let call_attribute = "hamlet.subtractor.generic_call.v2"
let callee_attribute = "hamlet.subtractor.generic_callee.v2"
let source_attribute = "hamlet.subtractor.generic_source.v2"
let specialized_attribute = "hamlet.subtractor.generic_specialized.v2"

type call = { id : string; loc : Location.t; callee_loc : Location.t }

type refusal_reason = Legacy_forward_extension
type refusal = { loc : Location.t; reason : refusal_reason }

type prepared = {
  base_structure : structure;
  probe_structure : structure;
  calls : call list;
  refusals : refusal list;
}

let refusal_message = function
  | Legacy_forward_extension ->
      "[%hamlet.forward.auto] is no longer part of the public syntax; remove \
       it because direct calls to [@hamlet.generic] functions are specialized \
       automatically"

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

let has_attribute name expression =
  List.exists
    (fun attribute -> String.equal attribute.attr_name.txt name)
    expression.pexp_attributes

let legacy_extension = function
  | { pexp_desc = Pexp_extension ({ txt; _ }, PStr []); _ } ->
      String.equal txt legacy_extension_name
  | _ -> false

let ordinary_identifier name =
  match name.[0] with 'A' .. 'Z' | '_' | 'a' .. 'z' -> true | _ -> false

let direct_callee = function
  | { pexp_desc = Pexp_ident { txt = Lident name; _ }; _ } ->
      String.length name > 0 && ordinary_identifier name
  | { pexp_desc = Pexp_ident { txt = Ldot _; _ }; _ } -> true
  | _ -> false

let has_positional_argument arguments =
  List.exists (fun (label, _) -> label = Nolabel) arguments

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
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        if legacy_extension expression then (
          refusals :=
            { loc = expression.pexp_loc; reason = Legacy_forward_extension }
            :: !refusals;
          expression)
        else
          let expression = super#expression expression in
          match expression.pexp_desc with
          | Pexp_apply (callee, arguments)
            when direct_callee callee
                 && has_positional_argument arguments
                 && not
                      (has_attribute
                         Hamlet_subtractor_generic_definition
                         .nested_call_attribute expression) ->
              let id =
                call_id ~structure_digest ~loc:expression.pexp_loc
                  ~ordinal:!ordinal
              in
              incr ordinal;
              calls :=
                { id; loc = expression.pexp_loc; callee_loc = callee.pexp_loc }
                :: !calls;
              let callee =
                add_attribute ~name:callee_attribute ~value:id callee
              in
              { expression with pexp_desc = Pexp_apply (callee, arguments) }
              |> add_attribute ~name:call_attribute ~value:id
          | _ -> expression
    end
  in
  let probe_structure = mapper#structure structure in
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
  | Missing_call of string
  | Duplicate_call of string

let finalization_error_message = function
  | Missing_attachment id -> "missing generic call classification for " ^ id
  | Duplicate_attachment id -> "duplicate generic call classification for " ^ id
  | Invalid_attachment id -> "invalid generic call classification for " ^ id
  | Contract_evaluation_failed id ->
      "generic helper contract cannot be instantiated for " ^ id
  | Generation_failed error -> Hamlet_subtractor_generator.error_message error
  | Missing_call id -> "final AST no longer contains generic call " ^ id
  | Duplicate_call id -> "final AST contains duplicate generic call " ^ id

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
      | Ok Core.Generic_resolution.Ignored -> Ok None
      | Ok (Core.Generic_resolution.Resolved (contract, input)) -> (
          match Core.Generic_contract.instantiate_slots ~input contract with
          | Error _ -> Error (Contract_evaluation_failed call.id)
          | Ok instantiated ->
              let rec generate accumulated = function
                | [] ->
                    Ok
                      (Some
                         (Hamlet_subtractor_generic_generator.bundle ~loc
                            (List.rev accumulated)))
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

let finalize ~calls ~attachments ~catalogues structure =
  let classification_error = ref None in
  let active_calls =
    calls
    |> List.filter (fun call ->
        match attachment_for_call attachments call.id with
        | Error error ->
            classification_error := Some error;
            false
        | Ok attachment -> (
            match
              Hamlet_subtractor_core.Generic_resolution.decode_call
                (Hamlet_subtractor_core.Protocol.generic_attachment_payload
                   attachment)
            with
            | Ok Hamlet_subtractor_core.Generic_resolution.Ignored -> false
            | Ok (Hamlet_subtractor_core.Generic_resolution.Resolved _) -> true
            | Error _ ->
                classification_error := Some (Invalid_attachment call.id);
                false))
  in
  let counts = Hashtbl.create (List.length active_calls) in
  let error = ref None in
  let same_location left right =
    String.equal left.loc_start.pos_fname right.loc_start.pos_fname
    && left.loc_start.pos_cnum = right.loc_start.pos_cnum
    && left.loc_end.pos_cnum = right.loc_end.pos_cnum
  in
  let call_at expression =
    match expression.pexp_desc with
    | Pexp_apply (callee, _) ->
        List.find_opt
          (fun (call : call) ->
            same_location call.loc expression.pexp_loc
            && same_location call.callee_loc callee.pexp_loc)
          active_calls
    | _ -> None
  in
  let mapper =
    object
      inherit Ast_traverse.map as super

      method! expression expression =
        match call_at expression with
        | None -> super#expression expression
        | Some call ->
            let count =
              Option.value (Hashtbl.find_opt counts call.id) ~default:0
            in
            Hashtbl.replace counts call.id (count + 1);
            begin match
              expression_for_call ~catalogues ~loc:expression.pexp_loc
                attachments call
            with
            | Error finalization_error ->
                error := Some finalization_error;
                expression
            | Ok None -> super#expression expression
            | Ok (Some evidence) ->
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
    end
  in
  let structure = mapper#structure structure in
  let strip =
    object
      inherit Ast_traverse.map as super

      method! attributes attributes =
        attributes
        |> List.filter (fun attribute ->
            not
              (List.exists
                 (String.equal attribute.attr_name.txt)
                 [
                   call_attribute;
                   callee_attribute;
                   source_attribute;
                   specialized_attribute;
                 ]))
        |> super#attributes
    end
  in
  let structure = strip#structure structure in
  match (!classification_error, !error) with
  | Some error, _ -> Error error
  | None, Some error -> Error error
  | None, None ->
      let rec validate = function
        | [] -> Ok structure
        | call :: rest -> (
            match Hashtbl.find_opt counts call.id with
            | None -> Error (Missing_call call.id)
            | Some 1 -> validate rest
            | Some _ -> Error (Duplicate_call call.id))
      in
      validate active_calls
