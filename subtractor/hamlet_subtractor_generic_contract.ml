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

let attribute_name = "hamlet.subtractor.generic_contract.v1"
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
