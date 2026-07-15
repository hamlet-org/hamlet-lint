module Core = Hamlet_subtractor_core
module Protocol = Core.Protocol

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.failf "%s: expected Ok" label

let expectation id kind =
  Protocol.generic_expectation ~id ~kind |> get_ok "expectation"

let attachment id kind payload =
  Protocol.generic_attachment ~id ~kind ~payload |> get_ok "attachment"

let tool_context : Protocol.tool_context =
  {
    ocaml_version = "5.5.0";
    hamlet_subtractor_version = "0.1.0";
    resolver_version = "0.1.0";
    catalogue_schema_version = 1;
  }

let compiler_flags : Protocol.compiler_flags =
  {
    debug = false;
    principal = false;
    recursive_types = false;
    alias_dependencies = true;
    use_threads = false;
    unboxed_types = false;
  }

let request generic_expectations =
  let probe_ast =
    Protocol.
      {
        path = "/tmp/generic-protocol.ast";
        input_name = "generic_protocol.ml";
        magic = "Caml1999M999";
        digest = "generic-ast";
        byte_length = 64;
      }
  in
  Protocol.request_with_generic_expectations ~generic_expectations
    ~request_id:"generic-request" ~source_file:"generic_protocol.ml"
    ~tool_name:"ocamlopt" ~probe_ast
    ~probe_unit:(Protocol.Synthetic_unit "Hamlet_subtractor_generic_protocol")
    ~tool_context ~context_fingerprint:"generic-context" ~include_dirs:[]
    ~hidden_include_dirs:[] ~visible_paths:[] ~hidden_paths:[] ~opens:[]
    ~package_mode:Protocol.Standalone ~compiler_flags ~expected_markers:[]

let response generic_attachments =
  Protocol.response ~generic_attachments ~request_id:"generic-request"
    ~context_fingerprint:"generic-context" ~ast_digest:"generic-ast" []

let expectation_ids request =
  Protocol.generic_expectations request
  |> List.map Protocol.generic_expectation_id

let attachment_ids response =
  Protocol.generic_attachments response
  |> List.map Protocol.generic_attachment_id

let test_deterministic_round_trips () =
  let definition = expectation "definition-b" Protocol.Definition in
  let call = expectation "call-a" Protocol.Call in
  let protocol_request = request [ definition; call ] |> get_ok "request" in
  let encoded_request = Protocol.encode_request protocol_request in
  let decoded_request =
    Protocol.decode_request encoded_request |> get_ok "decode request"
  in
  Alcotest.(check bool)
    "request round trip" true
    (Protocol.equal_request protocol_request decoded_request);
  Alcotest.(check string)
    "request re-encode" encoded_request
    (Protocol.encode_request decoded_request);
  Alcotest.(check (list string))
    "expectations sorted"
    [ "call-a"; "definition-b" ]
    (expectation_ids protocol_request);
  let definition = attachment "definition-b" Protocol.Definition "contract-b" in
  let call = attachment "call-a" Protocol.Call "contract-a" in
  let left = response [ definition; call ] |> get_ok "left response" in
  let right = response [ call; definition ] |> get_ok "right response" in
  Alcotest.(check string)
    "response ordering" (Protocol.encode left) (Protocol.encode right);
  let decoded =
    Protocol.decode (Protocol.encode left) |> get_ok "decode response"
  in
  Alcotest.(check bool) "response round trip" true (Protocol.equal left decoded);
  Alcotest.(check (list string))
    "attachments sorted"
    [ "call-a"; "definition-b" ]
    (attachment_ids decoded);
  let decoded_call = Protocol.generic_attachments decoded |> List.hd in
  Alcotest.(check bool)
    "attachment kind accessor" true
    (Protocol.generic_attachment_kind decoded_call = Protocol.Call);
  Alcotest.(check string)
    "attachment payload accessor" "contract-a"
    (Protocol.generic_attachment_payload decoded_call)

let test_attachment_correlation () =
  let definition = expectation "definition" Protocol.Definition in
  let call = expectation "call" Protocol.Call in
  let correlated_request = request [ definition; call ] |> get_ok "request" in
  let matching =
    response
      [
        attachment "definition" Protocol.Definition "definition-payload";
        attachment "call" Protocol.Call "call-payload";
      ]
    |> get_ok "matching response"
  in
  Protocol.validate_response ~request:correlated_request ~response:matching
  |> get_ok "matching correlation";
  let missing =
    response [ attachment "definition" Protocol.Definition "payload" ]
    |> get_ok "missing response"
  in
  begin match
    Protocol.validate_response ~request:correlated_request ~response:missing
  with
  | Error (Protocol.Missing_generic_attachment "call") -> ()
  | _ -> Alcotest.fail "missing generic attachment was accepted"
  end;
  let unexpected_request = request [] |> get_ok "empty request" in
  let unexpected =
    response [ attachment "extra" Protocol.Call "payload" ]
    |> get_ok "unexpected response"
  in
  begin match
    Protocol.validate_response ~request:unexpected_request ~response:unexpected
  with
  | Error (Protocol.Unexpected_generic_attachment "extra") -> ()
  | _ -> Alcotest.fail "unexpected generic attachment was accepted"
  end;
  let wrong_kind =
    response
      [
        attachment "definition" Protocol.Call "payload";
        attachment "call" Protocol.Call "payload";
      ]
    |> get_ok "wrong-kind response"
  in
  match
    Protocol.validate_response ~request:correlated_request ~response:wrong_kind
  with
  | Error
      (Protocol.Generic_attachment_kind_mismatch
         {
           id = "definition";
           expected = Protocol.Definition;
           actual = Protocol.Call;
         }) ->
      ()
  | _ -> Alcotest.fail "generic attachment kind mismatch was accepted"

let test_construction_and_payload_bounds () =
  begin match Protocol.generic_expectation ~id:"" ~kind:Protocol.Call with
  | Error Protocol.Empty_generic_attachment_id -> ()
  | _ -> Alcotest.fail "empty expectation identity was accepted"
  end;
  begin match
    Protocol.generic_attachment ~id:"attachment" ~kind:Protocol.Definition
      ~payload:""
  with
  | Error (Protocol.Empty_generic_attachment_payload "attachment") -> ()
  | _ -> Alcotest.fail "empty attachment payload was accepted"
  end;
  let oversized =
    String.make (Protocol.max_generic_attachment_payload_bytes + 1) 'x'
  in
  begin match
    Protocol.generic_attachment ~id:"attachment" ~kind:Protocol.Call
      ~payload:oversized
  with
  | Error (Protocol.Generic_attachment_payload_too_large _) -> ()
  | _ -> Alcotest.fail "oversized attachment payload was accepted"
  end;
  let duplicate = expectation "duplicate" Protocol.Definition in
  begin match request [ duplicate; duplicate ] with
  | Error (Protocol.Duplicate_generic_expectation "duplicate") -> ()
  | _ -> Alcotest.fail "duplicate generic expectation was accepted"
  end;
  let duplicate = attachment "duplicate" Protocol.Call "payload" in
  match response [ duplicate; duplicate ] with
  | Error (Protocol.Duplicate_generic_attachment "duplicate") -> ()
  | _ -> Alcotest.fail "duplicate generic attachment was accepted"

let test_decode_rejects_invalid_payloads () =
  let valid =
    response [ attachment "call" Protocol.Call "payload" ]
    |> get_ok "valid response"
    |> Protocol.encode
    |> Yojson.Safe.from_string
  in
  let replace_payload payload =
    match valid with
    | `Assoc fields ->
        let attachments =
          match List.assoc "generic_attachments" fields with
          | `List [ `Assoc attachment_fields ] ->
              `List
                [
                  `Assoc
                    (("payload", `String payload)
                    :: List.remove_assoc "payload" attachment_fields);
                ]
          | _ -> assert false
        in
        `Assoc
          (("generic_attachments", attachments)
          :: List.remove_assoc "generic_attachments" fields)
        |> Yojson.Safe.to_string
    | _ -> assert false
  in
  begin match Protocol.decode (replace_payload "") with
  | Error
      (Protocol.Malformed
         { path = [ "generic_attachments"; "0"; "payload" ]; _ }) ->
      ()
  | _ -> Alcotest.fail "decoded empty attachment payload was accepted"
  end;
  let oversized =
    String.make (Protocol.max_generic_attachment_payload_bytes + 1) 'x'
  in
  match Protocol.decode (replace_payload oversized) with
  | Error
      (Protocol.Malformed
         { path = [ "generic_attachments"; "0"; "payload" ]; _ }) ->
      ()
  | _ -> Alcotest.fail "decoded oversized attachment payload was accepted"

let () =
  Alcotest.run "hamlet-subtractor-generic-protocol"
    [
      ( "attachments",
        [
          Alcotest.test_case "deterministic round trips" `Quick
            test_deterministic_round_trips;
          Alcotest.test_case "request-response correlation" `Quick
            test_attachment_correlation;
          Alcotest.test_case "construction and payload bounds" `Quick
            test_construction_and_payload_bounds;
          Alcotest.test_case "decode rejects invalid payloads" `Quick
            test_decode_rejects_invalid_payloads;
        ] );
    ]
