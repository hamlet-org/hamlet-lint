type error =
  | Contract_encoding of Generic_contract.serialization_error
  | Contract_decoding of Generic_contract.decode_error
  | Certificate_validation of Effect_certificate.validation_error
  | Malformed_payload of string
  | Contract_digest_mismatch of { expected : string; actual : string }
  | Payload_too_large of { limit : int; actual : int }

type call = Ignored | Resolved of (Generic_contract.t * Effect_certificate.t)

let limit = Protocol.max_generic_attachment_payload_bytes

let bounded payload =
  let actual = String.length payload in
  if actual > limit then Error (Payload_too_large { limit; actual })
  else Ok payload

let encode_definition contract =
  Generic_contract.encode contract
  |> Result.map_error (fun error -> Contract_encoding error)
  |> fun result -> Result.bind result bounded

let decode_definition payload =
  if String.length payload > limit then
    Error (Payload_too_large { limit; actual = String.length payload })
  else
    Generic_contract.decode payload
    |> Result.map_error (fun error -> Contract_decoding error)

let encode_ignored_call () =
  `Assoc [ ("schema", `Int 2); ("status", `String "ignored") ]
  |> Yojson.Safe.to_string
  |> bounded

let encode_call ~contract ~input =
  let ( let* ) = Result.bind in
  let* contract_payload =
    Generic_contract.encode contract
    |> Result.map_error (fun error -> Contract_encoding error)
  in
  let* contract_digest =
    Generic_contract.digest contract
    |> Result.map_error (fun error -> Contract_encoding error)
  in
  let payload =
    `Assoc
      [
        ("schema", `Int 2);
        ("status", `String "resolved");
        ("contract", `String contract_payload);
        ("contract_digest", `String contract_digest);
        ("errors", Protocol.evidence_to_json (Effect_certificate.errors input));
        ( "requirements",
          Protocol.evidence_to_json (Effect_certificate.requirements input) );
      ]
    |> Yojson.Safe.to_string
  in
  bounded payload

let decode_resolved_call fields =
  let ( let* ) = Result.bind in
  let malformed message = Error (Malformed_payload message) in
  let field name fields =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> malformed ("missing field " ^ name)
  in
  let string_field name fields =
    let* value = field name fields in
    match value with
    | `String value -> Ok value
    | _ -> malformed ("field " ^ name ^ " must be a string")
  in
  let* contract_payload = string_field "contract" fields in
  let* expected_digest = string_field "contract_digest" fields in
  let* contract = decode_definition contract_payload in
  let* actual_digest =
    Generic_contract.digest contract
    |> Result.map_error (fun error -> Contract_encoding error)
  in
  if not (String.equal expected_digest actual_digest) then
    Error
      (Contract_digest_mismatch
         { expected = expected_digest; actual = actual_digest })
  else
    let* errors_json = field "errors" fields in
    let* requirements_json = field "requirements" fields in
    let* errors =
      Protocol.evidence_of_json [ "errors" ] errors_json
      |> Result.map_error (function
        | Protocol.Malformed { message; _ } -> Malformed_payload message
        | Protocol.Version_mismatch { expected; actual } ->
            Malformed_payload
              (Printf.sprintf
                 "evidence protocol version mismatch: expected %d, got %d"
                 expected actual))
    in
    let* requirements =
      Protocol.evidence_of_json [ "requirements" ] requirements_json
      |> Result.map_error (function
        | Protocol.Malformed { message; _ } -> Malformed_payload message
        | Protocol.Version_mismatch { expected; actual } ->
            Malformed_payload
              (Printf.sprintf
                 "evidence protocol version mismatch: expected %d, got %d"
                 expected actual))
    in
    let* input =
      Effect_certificate.create ~errors ~requirements
      |> Result.map_error (fun error -> Certificate_validation error)
    in
    Ok (Resolved (contract, input))

let decode_call payload =
  let ( let* ) = Result.bind in
  let malformed message = Error (Malformed_payload message) in
  let field name fields =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> malformed ("missing field " ^ name)
  in
  if String.length payload > limit then
    Error (Payload_too_large { limit; actual = String.length payload })
  else
    try
      match Yojson.Safe.from_string payload with
      | `Assoc fields ->
          let* schema_json = field "schema" fields in
          let* () =
            match schema_json with
            | `Int 2 -> Ok ()
            | `Int value ->
                malformed (Printf.sprintf "unsupported call schema %d" value)
            | _ -> malformed "field schema must be an integer"
          in
          let* status = field "status" fields in
          begin match status with
          | `String "ignored" -> Ok Ignored
          | `String "resolved" -> decode_resolved_call fields
          | `String value -> malformed ("unknown call status " ^ value)
          | _ -> malformed "field status must be a string"
          end
      | _ -> malformed "call payload must be an object"
    with Yojson.Json_error message -> malformed ("malformed JSON: " ^ message)
