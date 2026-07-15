open Hamlet_subtractor_core

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.fail (label ^ " unexpectedly failed")

let identity name =
  Identity.make ~module_path:[ "Fixture" ] ~declaration_name:name
    ~interface_digest:"digest"
  |> get_ok "identity"

let leaf name label =
  let identity = identity name in
  let member =
    Atom.make ~kind:Kind.Error ~declaration:identity ~label
      ~payload:Atom.No_payload
    |> get_ok "atom"
  in
  Leaf.error ~identity ~members:[ member ]
    ~materialization:Leaf.Structural_variant
  |> get_ok "leaf"

let proof kind leaves =
  Proof.create ~kind ~origin:Proof.Closed_row ~leaves |> get_ok "proof"

let certificate errors =
  Effect_certificate.create
    ~errors:(Effect_certificate.exact errors)
    ~requirements:(Effect_certificate.exact (proof Kind.Requirement []))
  |> get_ok "certificate"

let fixture () =
  let missing = leaf "missing" "Missing" in
  let timeout = leaf "timeout" "Timeout" in
  let slot_id = Generic_contract.slot_id "e:slot" |> get_ok "slot id" in
  let recovery = Generic_contract.clear Kind.Error in
  let slot =
    Generic_contract.slot ~id:slot_id ~ordinal:0 ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recovery
    |> get_ok "slot"
  in
  let output =
    Generic_contract.catch ~inputs:[] ~source:Generic_contract.input_certificate
      ~handled:[ missing ] ~explicitly_forwarded:[] ~recoveries:[]
    |> get_ok "output"
  in
  let contract =
    Generic_contract.create ~helper_fingerprint:"Fixture.helper"
      ~definition_context:"digest" ~effect_parameter:0 ~slots:[ slot ] ~output
    |> get_ok "contract"
  in
  (contract, certificate (proof Kind.Error [ missing; timeout ]))

let test_definition_round_trip () =
  let contract, _ = fixture () in
  let payload =
    Generic_resolution.encode_definition contract |> get_ok "encode definition"
  in
  let decoded =
    Generic_resolution.decode_definition payload |> get_ok "decode definition"
  in
  Alcotest.(check bool)
    "same contract" true
    (Generic_contract.equal contract decoded)

let test_call_round_trip () =
  let contract, input = fixture () in
  let payload =
    Generic_resolution.encode_call ~contract ~input |> get_ok "encode call"
  in
  let decoded_contract, decoded_input =
    Generic_resolution.decode_call payload |> get_ok "decode call"
  in
  Alcotest.(check bool)
    "same contract" true
    (Generic_contract.equal contract decoded_contract);
  Alcotest.(check bool)
    "same input" true
    (Effect_certificate.equal input decoded_input)

let test_digest_tampering_is_rejected () =
  let contract, input = fixture () in
  let payload =
    Generic_resolution.encode_call ~contract ~input |> get_ok "encode call"
  in
  let tampered =
    match Yojson.Safe.from_string payload with
    | `Assoc fields ->
        `Assoc
          (("contract_digest", `String "not-the-contract-digest")
          :: List.remove_assoc "contract_digest" fields)
        |> Yojson.Safe.to_string
    | _ -> assert false
  in
  match Generic_resolution.decode_call tampered with
  | Error (Generic_resolution.Contract_digest_mismatch _) -> ()
  | Error _ -> Alcotest.fail "tampering produced the wrong refusal"
  | Ok _ -> Alcotest.fail "tampered contract digest was accepted"

let () =
  Alcotest.run "hamlet-subtractor-generic-resolution"
    [
      ( "payloads",
        [
          Alcotest.test_case "definition round trip" `Quick
            test_definition_round_trip;
          Alcotest.test_case "call round trip" `Quick test_call_round_trip;
          Alcotest.test_case "digest tampering" `Quick
            test_digest_tampering_is_rejected;
        ] );
    ]
