open Ppxlib

type slot_kind = Error | Requirement
type owner_form = Direct | Pipe

type slot = {
  ordinal : int;
  marker_id : string;
  kind : slot_kind;
  owner_form : owner_form;
  handled_cases : int;
  guarded : bool;
  handled_digest : string;
}

type t = { helper : string; source_parameter : int; slots : slot list }

let provisional_attribute_name =
  "hamlet.subtractor.generic_contract.provisional.v1"

let retained_attribute_name = "hamlet.subtractor.generic_contract.v2"
let attribute_name = provisional_attribute_name
let schema_version = 1
let maximum_payload_bytes = 65_536

let sanitize_identifier value =
  String.map
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_') as character -> character
      | _ -> '_')
    value

let companion_name helper =
  "Hamlet_subtractor_contract__" ^ sanitize_identifier helper

let slot_kind_to_string = function
  | Error -> "error"
  | Requirement -> "requirement"

let owner_form_to_string = function Direct -> "direct" | Pipe -> "pipe"

let slot_to_yojson slot =
  `Assoc
    [
      ("ordinal", `Int slot.ordinal);
      ("marker_id", `String slot.marker_id);
      ("kind", `String (slot_kind_to_string slot.kind));
      ("owner_form", `String (owner_form_to_string slot.owner_form));
      ("handled_cases", `Int slot.handled_cases);
      ("guarded", `Bool slot.guarded);
      ("handled_digest", `String slot.handled_digest);
    ]

let encode_provisional contract =
  let payload =
    `Assoc
      [
        ("schema", `Int schema_version);
        ("provisional", `Bool true);
        ("helper", `String contract.helper);
        ("source_parameter", `Int contract.source_parameter);
        ("slots", `List (List.map slot_to_yojson contract.slots));
      ]
    |> Yojson.Safe.to_string
  in
  if String.length payload > maximum_payload_bytes then
    Result.Error
      (Printf.sprintf "generic helper contract is %d bytes; maximum is %d"
         (String.length payload) maximum_payload_bytes)
  else Result.Ok payload

let decode_provisional payload =
  let ( let* ) = Result.bind in
  let error message = Result.error message in
  let field name fields =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> error ("missing field " ^ name)
  in
  let string_field name fields =
    let* value = field name fields in
    match value with
    | `String value -> Ok value
    | _ -> error ("field " ^ name ^ " must be a string")
  in
  let int_field name fields =
    let* value = field name fields in
    match value with
    | `Int value -> Ok value
    | _ -> error ("field " ^ name ^ " must be an integer")
  in
  let bool_field name fields =
    let* value = field name fields in
    match value with
    | `Bool value -> Ok value
    | _ -> error ("field " ^ name ^ " must be a boolean")
  in
  let slot_of_json = function
    | `Assoc fields ->
        let* ordinal = int_field "ordinal" fields in
        let* marker_id = string_field "marker_id" fields in
        let* kind = string_field "kind" fields in
        let* kind =
          match kind with
          | "error" -> Ok Error
          | "requirement" -> Ok Requirement
          | _ -> error "field kind has an unsupported value"
        in
        let* owner_form = string_field "owner_form" fields in
        let* owner_form =
          match owner_form with
          | "direct" -> Ok Direct
          | "pipe" -> Ok Pipe
          | _ -> error "field owner_form has an unsupported value"
        in
        let* handled_cases = int_field "handled_cases" fields in
        let* guarded = bool_field "guarded" fields in
        let* handled_digest = string_field "handled_digest" fields in
        if ordinal < 0 then error "slot ordinal must be nonnegative"
        else if handled_cases < 0 then
          error "slot handled_cases must be nonnegative"
        else if String.trim marker_id = "" then error "empty slot marker_id"
        else
          Ok
            {
              ordinal;
              marker_id;
              kind;
              owner_form;
              handled_cases;
              guarded;
              handled_digest;
            }
    | _ -> error "slot must be an object"
  in
  let slots_of_json = function
    | `List slots ->
        let rec loop accumulated = function
          | [] -> Ok (List.rev accumulated)
          | slot :: rest ->
              let* slot = slot_of_json slot in
              loop (slot :: accumulated) rest
        in
        loop [] slots
    | _ -> error "field slots must be a list"
  in
  if String.length payload > maximum_payload_bytes then
    error
      (Printf.sprintf "generic helper contract is %d bytes; maximum is %d"
         (String.length payload) maximum_payload_bytes)
  else
    try
      match Yojson.Safe.from_string payload with
      | `Assoc fields ->
          let* schema = int_field "schema" fields in
          if schema <> schema_version then
            error (Printf.sprintf "unsupported provisional schema %d" schema)
          else
            let* provisional = bool_field "provisional" fields in
            if not provisional then error "contract is not provisional"
            else
              let* helper = string_field "helper" fields in
              let* source_parameter = int_field "source_parameter" fields in
              let* slots_json = field "slots" fields in
              let* slots = slots_of_json slots_json in
              if String.trim helper = "" then error "empty helper name"
              else if source_parameter < 0 then
                error "source_parameter must be nonnegative"
              else
                let ordinals = List.map (fun slot -> slot.ordinal) slots in
                let marker_ids = List.map (fun slot -> slot.marker_id) slots in
                if
                  List.length ordinals
                  <> List.length (List.sort_uniq Int.compare ordinals)
                then error "duplicate slot ordinal"
                else if
                  List.length marker_ids
                  <> List.length (List.sort_uniq String.compare marker_ids)
                then error "duplicate slot marker_id"
                else Ok { helper; source_parameter; slots }
      | _ -> error "contract must be an object"
    with Yojson.Json_error message -> error ("malformed JSON: " ^ message)

let attribute_payload attribute =
  if String.equal attribute.Ppxlib.Parsetree.attr_name.txt attribute_name then
    match attribute.attr_payload with
    | PStr
        [
          {
            pstr_desc =
              Pstr_eval
                ( { pexp_desc = Pexp_constant (Pconst_string (value, _, _)); _ },
                  _ );
            _;
          };
        ] ->
        Some value
    | _ -> None
  else None

let provisional_contracts structure =
  let contracts = ref [] in
  let iterator =
    object
      inherit Ppxlib.Ast_traverse.iter as super

      method! module_binding binding =
        List.filter_map attribute_payload binding.pmb_attributes
        |> List.iter (fun payload ->
            match decode_provisional payload with
            | Ok contract -> contracts := contract :: !contracts
            | Error message -> raise (Invalid_argument message));
        super#module_binding binding
    end
  in
  try
    iterator#structure structure;
    Ok (List.rev !contracts)
  with Invalid_argument message -> Error message

let definition_expectations structure =
  let ( let* ) = Result.bind in
  let* contracts = provisional_contracts structure in
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | contract :: rest ->
        let id = "definition:" ^ contract.helper in
        let* expectation =
          Hamlet_subtractor_core.Protocol.generic_expectation ~id
            ~kind:Hamlet_subtractor_core.Protocol.Definition
          |> Result.map_error (fun _ ->
              "invalid generic definition attachment identity " ^ id)
        in
        loop (expectation :: accumulated) rest
  in
  loop [] contracts

let finalize_definitions ~attachments structure =
  let module Protocol = Hamlet_subtractor_core.Protocol in
  let payload_for helper =
    let id = "definition:" ^ helper in
    attachments
    |> List.filter (fun attachment ->
        String.equal id (Protocol.generic_attachment_id attachment)
        && Protocol.generic_attachment_kind attachment = Protocol.Definition)
    |> function
    | [ attachment ] -> Ok (Protocol.generic_attachment_payload attachment)
    | [] -> Error ("missing exact generic helper contract for " ^ helper)
    | _ -> Error ("duplicate exact generic helper contract for " ^ helper)
  in
  let error = ref None in
  let mapper =
    object
      inherit Ppxlib.Ast_traverse.map as super

      method! module_binding binding =
        let attributes =
          List.map
            (fun attribute ->
              match attribute_payload attribute with
              | None -> attribute
              | Some provisional -> (
                  match decode_provisional provisional with
                  | Error message ->
                      error := Some message;
                      attribute
                  | Ok contract -> (
                      match payload_for contract.helper with
                      | Error message ->
                          error := Some message;
                          attribute
                      | Ok payload ->
                          {
                            attribute with
                            attr_name =
                              {
                                attribute.attr_name with
                                txt = retained_attribute_name;
                              };
                            attr_payload =
                              PStr
                                [
                                  Ppxlib.Ast_builder.Default.pstr_eval
                                    ~loc:attribute.attr_loc
                                    (Ppxlib.Ast_builder.Default.estring
                                       ~loc:attribute.attr_loc payload)
                                    [];
                                ];
                          })))
            binding.pmb_attributes
        in
        super#module_binding { binding with pmb_attributes = attributes }
    end
  in
  let structure = mapper#structure structure in
  match !error with None -> Ok structure | Some message -> Error message
