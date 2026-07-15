module Core = Hamlet_subtractor_core
module Atom = Core.Atom
module Effect_certificate = Core.Effect_certificate
module Generic_contract = Core.Generic_contract
module Identity = Core.Identity
module Kind = Core.Kind
module Leaf = Core.Leaf
module Proof = Core.Proof
module Residual = Core.Residual

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.failf "%s: expected Ok" label

let identity path declaration =
  Identity.make ~module_path:path ~declaration_name:declaration
    ~interface_digest:"contract-test"
  |> get_ok "identity"

let error_leaf declaration label =
  let identity = identity [ "Errors" ] declaration in
  let atom =
    Atom.error ~declaration:identity ~label ~payload:Atom.No_payload
    |> get_ok "error atom"
  in
  Leaf.error ~identity ~members:[ atom ] ~materialization:Leaf.Direct
  |> get_ok "error leaf"

let structural_error_leaf declaration label =
  let identity = identity [ "Structural" ] declaration in
  let atom =
    Atom.error ~declaration:identity ~label ~payload:Atom.No_payload
    |> get_ok "structural error atom"
  in
  Leaf.error ~identity ~members:[ atom ]
    ~materialization:Leaf.Structural_variant
  |> get_ok "structural error leaf"

let grouped_error_leaf declaration labels =
  let identity = identity [ "Grouped" ] declaration in
  let members =
    List.map
      (fun label ->
        Atom.error ~declaration:identity ~label ~payload:Atom.No_payload
        |> get_ok "grouped error atom")
      labels
  in
  Leaf.error ~identity ~members ~materialization:Leaf.Direct
  |> get_ok "grouped error leaf"

let requirement_leaf module_name label =
  let identity = identity [ module_name; "Tag" ] "r" in
  let atom =
    Atom.requirement ~declaration:identity ~label ~payload:Atom.No_payload
    |> get_ok "requirement atom"
  in
  Leaf.requirement ~identity ~member:atom ~materialization:Leaf.Requirement_tag
  |> get_ok "requirement leaf"

let proof kind leaves =
  Proof.create ~kind ~origin:Proof.Closed_row ~leaves |> get_ok "proof"

let certificate errors requirements =
  Effect_certificate.create
    ~errors:(Effect_certificate.exact (proof Kind.Error errors))
    ~requirements:
      (Effect_certificate.exact (proof Kind.Requirement requirements))
  |> get_ok "certificate"

let concrete errors requirements =
  certificate errors requirements |> Generic_contract.concrete

let exact_leaves evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Exact_proof proof -> Proof.leaves proof
  | Effect_certificate.Opaque_reasons _ -> Alcotest.fail "expected exact proof"

let names leaves =
  leaves
  |> List.map (fun leaf -> Identity.to_string (Leaf.identity leaf))
  |> List.sort String.compare

let labels leaves =
  leaves
  |> List.concat_map Leaf.members
  |> List.map Atom.label
  |> List.sort String.compare

let check_names label expected evidence =
  Alcotest.(check (list string)) label expected (names (exact_leaves evidence))

let slot_id value = Generic_contract.slot_id value |> get_ok "slot id"

let diagnostic_name = function
  | Core.Diagnostic.Open_row -> "open row"
  | Abstract_alias _ -> "abstract alias"
  | Unresolved_row -> "unresolved row"
  | Polymorphic_parameter -> "polymorphic parameter"
  | Opaque_origin -> "opaque origin"
  | Higher_order_flow -> "higher-order flow"
  | Invalid_owner -> "invalid owner"
  | Invalid_error_catalogue _ -> "invalid error catalogue"
  | Unsupported_pattern -> "unsupported pattern"
  | Unsupported_handler_rhs -> "unsupported handler body"
  | Ambiguous_handler -> "ambiguous handler"
  | Recursive_dependency _ -> "recursive dependency"
  | Unsupported_payload _ -> "unsupported payload"
  | Leaf_outside_universe _ -> "leaf outside universe"
  | Atoms_outside_universe _ -> "atoms outside universe"
  | Partially_handled_group _ -> "partially handled group"
  | Unmaterializable_leaf _ -> "unmaterializable leaf"
  | Grouped_requirement _ -> "grouped requirement"
  | Duplicate_unguarded_arm _ -> "duplicate arm"
  | Conflicting_recovery_leaf _ -> "conflicting recovery leaf"
  | Wrong_channel _ -> "wrong channel"

let test_two_channel_substitution_and_slots () =
  let missing = error_leaf "missing" "Missing" in
  let timeout = error_leaf "timeout" "Timeout" in
  let recovery = error_leaf "recovery" "Recovery" in
  let logger = requirement_leaf "Logger" "Logger" in
  let clock = requirement_leaf "Clock" "Clock" in
  let audit = requirement_leaf "Audit" "Audit" in
  let recovery_certificate = concrete [ recovery ] [ audit ] in
  let after_catch =
    Generic_contract.catch ~inputs:[] ~source:Generic_contract.input_certificate
      ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recoveries:[ recovery_certificate ]
    |> get_ok "symbolic catch"
  in
  let after_provide =
    Generic_contract.provide ~inputs:[] ~source:after_catch ~handled:[ logger ]
      ~explicitly_forwarded:[] ~handlers:[]
    |> get_ok "symbolic provide"
  in
  let substituted =
    Generic_contract.substitute ~input:after_catch
      Generic_contract.input_certificate
  in
  Alcotest.(check bool)
    "symbolic input substitution" true
    (Generic_contract.equal_expression
       (Generic_contract.errors after_catch)
       (Generic_contract.errors substituted)
    && Generic_contract.equal_expression
         (Generic_contract.requirements after_catch)
         (Generic_contract.requirements substituted));
  let error_slot =
    Generic_contract.slot ~id:(slot_id "errors-0") ~ordinal:0 ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.exact (proof Kind.Error [ recovery ]))
    |> get_ok "error slot"
  in
  let requirement_slot =
    Generic_contract.slot ~id:(slot_id "requirements-1") ~ordinal:1
      ~kind:Kind.Requirement
      ~input:(Generic_contract.requirements after_catch)
      ~claimed:[ logger ] ~handled:[ logger ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Requirement)
    |> get_ok "requirement slot"
  in
  let contract =
    Generic_contract.create ~helper_fingerprint:"Helper.generic/1"
      ~effect_parameter:1
      ~slots:[ requirement_slot; error_slot ]
      ~output:after_provide
    |> get_ok "contract"
  in
  let caller = certificate [ missing; timeout ] [ logger; clock ] in
  let evaluated =
    Generic_contract.evaluate ~input:caller (Generic_contract.output contract)
    |> get_ok "evaluate"
  in
  check_names "output errors"
    [ "Errors.recovery"; "Errors.timeout" ]
    (Effect_certificate.errors evaluated);
  check_names "output requirements"
    [ "Audit.Tag.r"; "Clock.Tag.r" ]
    (Effect_certificate.requirements evaluated);
  let instantiated =
    Generic_contract.instantiate_slots ~input:caller contract
    |> get_ok "instantiate slots"
  in
  let first, second =
    match instantiated with
    | [ first; second ] -> (first, second)
    | _ -> Alcotest.fail "expected two ordered slots"
  in
  Alcotest.(check string)
    "first slot" "errors-0"
    (first
    |> Generic_contract.instantiated_slot
    |> Generic_contract.slot_id_value
    |> Generic_contract.slot_id_to_string);
  check_names "first slot output"
    [ "Errors.recovery"; "Errors.timeout" ]
    (Generic_contract.instantiated_residual first
    |> Residual.output
    |> proof Kind.Error
    |> Effect_certificate.exact);
  Alcotest.(check string)
    "second slot" "requirements-1"
    (second
    |> Generic_contract.instantiated_slot
    |> Generic_contract.slot_id_value
    |> Generic_contract.slot_id_to_string);
  check_names "second slot output"
    [ "Audit.Tag.r"; "Clock.Tag.r" ]
    (Generic_contract.instantiated_residual second
    |> Residual.output
    |> proof Kind.Requirement
    |> Effect_certificate.exact)

let simple_contract ?(slots = []) () =
  Generic_contract.create ~helper_fingerprint:"Helper.simple/1"
    ~effect_parameter:0 ~slots ~output:Generic_contract.input_certificate
  |> get_ok "simple contract"

let test_deterministic_round_trip_and_digest () =
  let missing = error_leaf "missing" "Missing" in
  let make_slot id ordinal =
    Generic_contract.slot ~id:(slot_id id) ~ordinal ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
    |> get_ok "slot"
  in
  let first = make_slot "first" 0 in
  let second = make_slot "second" 1 in
  let contract = simple_contract ~slots:[ second; first ] () in
  let encoded = Generic_contract.encode contract |> get_ok "encode" in
  let decoded = Generic_contract.decode encoded |> get_ok "decode" in
  let encoded_again = Generic_contract.encode decoded |> get_ok "re-encode" in
  Alcotest.(check string) "deterministic encoding" encoded encoded_again;
  Alcotest.(check bool)
    "round trip" true
    (Generic_contract.equal contract decoded);
  Alcotest.(check string)
    "stable digest"
    (Generic_contract.digest contract |> get_ok "digest")
    (Generic_contract.digest decoded |> get_ok "decoded digest")

let test_malformed_and_oversized_contracts () =
  begin match Generic_contract.decode "{" with
  | Error (Generic_contract.Malformed_json _) -> ()
  | _ -> Alcotest.fail "malformed JSON was accepted"
  end;
  let encoded =
    Generic_contract.encode (simple_contract ()) |> get_ok "encode"
  in
  let json = Yojson.Safe.from_string encoded in
  let wrong_version =
    match json with
    | `Assoc fields ->
        `Assoc
          (("schema_version", `Int 999)
          :: List.remove_assoc "schema_version" fields)
        |> Yojson.Safe.to_string
    | _ -> assert false
  in
  begin match Generic_contract.decode wrong_version with
  | Error
      (Generic_contract.Schema_version_mismatch { expected = 2; actual = 999 })
    ->
      ()
  | _ -> Alcotest.fail "schema mismatch was accepted"
  end;
  let duplicate_slots =
    let missing = error_leaf "missing" "Missing" in
    let slot =
      Generic_contract.slot ~id:(slot_id "duplicate") ~ordinal:0
        ~kind:Kind.Error
        ~input:(Generic_contract.input Kind.Error)
        ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
        ~recovery:(Generic_contract.clear Kind.Error)
      |> get_ok "duplicate fixture slot"
    in
    let contract = simple_contract ~slots:[ slot ] () in
    match
      Generic_contract.encode contract
      |> get_ok "duplicate fixture encode"
      |> Yojson.Safe.from_string
    with
    | `Assoc fields ->
        let slot_json =
          match List.assoc "slots" fields with
          | `List [ slot_json ] -> slot_json
          | _ -> assert false
        in
        `Assoc
          (("slots", `List [ slot_json; slot_json ])
          :: List.remove_assoc "slots" fields)
        |> Yojson.Safe.to_string
    | _ -> assert false
  in
  begin match Generic_contract.decode duplicate_slots with
  | Error (Generic_contract.Invalid_contract (Duplicate_slot_id _)) -> ()
  | _ -> Alcotest.fail "malformed duplicate-slot contract was accepted"
  end;
  let oversized = String.make (Generic_contract.max_encoded_bytes + 1) 'x' in
  begin match Generic_contract.decode oversized with
  | Error (Generic_contract.Decode_contract_too_large _) -> ()
  | _ -> Alcotest.fail "oversized contract was accepted"
  end;
  let oversized_contract =
    Generic_contract.create
      ~helper_fingerprint:(String.make Generic_contract.max_encoded_bytes 'h')
      ~effect_parameter:0 ~slots:[] ~output:Generic_contract.input_certificate
    |> get_ok "oversized contract value"
  in
  begin match Generic_contract.encode oversized_contract with
  | Error (Generic_contract.Encoded_contract_too_large _) -> ()
  | _ -> Alcotest.fail "oversized encoded metadata was accepted"
  end

let test_duplicate_slots_and_expression_limits () =
  let missing = error_leaf "missing" "Missing" in
  let make_slot id ordinal =
    Generic_contract.slot ~id:(slot_id id) ~ordinal ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
    |> get_ok "slot"
  in
  begin match
    Generic_contract.create ~helper_fingerprint:"Helper.duplicate/1"
      ~effect_parameter:0
      ~slots:[ make_slot "same" 0; make_slot "same" 1 ]
      ~output:Generic_contract.input_certificate
  with
  | Error (Generic_contract.Duplicate_slot_id _) -> ()
  | _ -> Alcotest.fail "duplicate slot ID was accepted"
  end;
  let rec nest count expression =
    if count = 0 then expression
    else
      Generic_contract.union ~kind:Kind.Error ~operation:Proof.Chain ~inputs:[]
        [ expression ]
      |> get_ok "nested expression"
      |> nest (count - 1)
  in
  let too_deep =
    nest Generic_contract.max_expression_depth
      (Generic_contract.input Kind.Error)
  in
  let output =
    Generic_contract.certificate ~errors:too_deep
      ~requirements:(Generic_contract.input Kind.Requirement)
    |> get_ok "deep output"
  in
  begin match
    Generic_contract.create ~helper_fingerprint:"Helper.deep/1"
      ~effect_parameter:0 ~slots:[] ~output
  with
  | Error (Generic_contract.Expression_too_deep _) -> ()
  | _ -> Alcotest.fail "overly deep expression was accepted"
  end

let test_guarded_claim_remains_residual () =
  let guarded = error_leaf "guarded" "Guarded" in
  let other = error_leaf "other" "Other" in
  let slot =
    Generic_contract.slot ~id:(slot_id "guarded-claim") ~ordinal:0
      ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ guarded ] ~handled:[] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
    |> get_ok "guarded slot"
  in
  let caller = certificate [ guarded; other ] [] in
  let instantiated =
    Generic_contract.instantiate_slot ~input:caller slot
    |> get_ok "guarded slot instantiation"
  in
  Alcotest.(check (list string))
    "guarded claim is routed" [ "Errors.guarded" ]
    (Generic_contract.slot_claimed slot |> names);
  Alcotest.(check (list string))
    "guarded claim remains in residual"
    [ "Errors.guarded"; "Errors.other" ]
    (Generic_contract.instantiated_residual instantiated
    |> Residual.residual
    |> names);
  begin match
    Generic_contract.slot ~id:(slot_id "invalid-claim") ~ordinal:1
      ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[] ~handled:[ guarded ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
  with
  | Error
      (Generic_contract.Slot_expression_error
         (Generic_contract.Partition_leaf_not_claimed _)) ->
      ()
  | _ -> Alcotest.fail "unclaimed handled leaf was accepted"
  end

let test_structural_partition_refines_grouped_caller_leaf () =
  let missing = structural_error_leaf "missing" "Missing" in
  let grouped = grouped_error_leaf "caller" [ "Missing"; "Timeout" ] in
  let slot =
    Generic_contract.slot
      ~id:(slot_id "structural-group")
      ~ordinal:0 ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ missing ] ~handled:[ missing ] ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
    |> get_ok "structural group slot"
  in
  let caller = certificate [ grouped ] [] in
  let instantiated =
    match Generic_contract.instantiate_slot ~input:caller slot with
    | Ok instantiated -> instantiated
    | Error (Generic_contract.Residual_error diagnostic) ->
        Alcotest.failf "structural group residual: %s"
          (diagnostic_name diagnostic)
    | Error (Generic_contract.Opaque_expression _) ->
        Alcotest.fail "structural group became opaque"
    | Error (Generic_contract.Certificate_error _) ->
        Alcotest.fail "structural group certificate failed"
    | Error (Generic_contract.Evaluated_wrong_kind _) ->
        Alcotest.fail "structural group changed kind"
  in
  Alcotest.(check (list string))
    "refined input" [ "Missing"; "Timeout" ]
    (Generic_contract.instantiated_residual instantiated
    |> Residual.input
    |> Proof.leaves
    |> labels);
  Alcotest.(check (list string))
    "precise residual" [ "Timeout" ]
    (Generic_contract.instantiated_residual instantiated
    |> Residual.residual
    |> labels)

let test_nominal_partition_does_not_align_by_shape () =
  let contract_leaf = error_leaf "contract_missing" "Missing" in
  let caller_leaf = error_leaf "caller_missing" "Missing" in
  let slot =
    Generic_contract.slot ~id:(slot_id "nominal-shape") ~ordinal:0
      ~kind:Kind.Error
      ~input:(Generic_contract.input Kind.Error)
      ~claimed:[ contract_leaf ] ~handled:[ contract_leaf ]
      ~explicitly_forwarded:[]
      ~recovery:(Generic_contract.clear Kind.Error)
    |> get_ok "nominal slot"
  in
  let caller = certificate [ caller_leaf ] [] in
  match Generic_contract.instantiate_slot ~input:caller slot with
  | Error
      (Generic_contract.Residual_error
         (Core.Diagnostic.Leaf_outside_universe identity)) ->
      Alcotest.(check string)
        "contract identity is reported"
        (Identity.to_string (Leaf.identity contract_leaf))
        (Identity.to_string identity)
  | _ -> Alcotest.fail "nominal leaves aligned by structural shape"

let () =
  Alcotest.run "hamlet-subtractor-generic-contract"
    [
      ( "contract",
        [
          Alcotest.test_case "two-channel substitution and slots" `Quick
            test_two_channel_substitution_and_slots;
          Alcotest.test_case "deterministic round trip and digest" `Quick
            test_deterministic_round_trip_and_digest;
          Alcotest.test_case "malformed and oversized payloads" `Quick
            test_malformed_and_oversized_contracts;
          Alcotest.test_case "duplicate slots and expression limits" `Quick
            test_duplicate_slots_and_expression_limits;
          Alcotest.test_case "guarded claim remains residual" `Quick
            test_guarded_claim_remains_residual;
          Alcotest.test_case "structural partition refines grouped caller leaf"
            `Quick test_structural_partition_refines_grouped_caller_leaf;
          Alcotest.test_case "nominal partition keeps declaration identity"
            `Quick test_nominal_partition_does_not_align_by_shape;
        ] );
    ]
