module Core = Hamlet_subtractor_core
module Kind = Core.Kind
module Identity = Core.Identity
module Type_identity = Core.Type_identity
module Atom = Core.Atom
module Leaf = Core.Leaf
module Proof = Core.Proof
module Residual = Core.Residual
module Diagnostic = Core.Diagnostic
module Effect_certificate = Core.Effect_certificate
module Observation = Core.Observation
module Candidate = Core.Candidate
module Protocol = Core.Protocol

let get_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.failf "%s: expected Ok" label

let identity ?(digest = "cmi-a") path declaration =
  Identity.make ~module_path:path ~declaration_name:declaration
    ~interface_digest:digest
  |> get_ok "identity"

let error_atom
    ?(declaration = identity [ "Storage"; "Errors" ] "read_error")
    ?(payload = Atom.No_payload)
    label =
  Atom.error ~declaration ~label ~payload |> get_ok "error atom"

let requirement_atom
    ?(declaration = identity [ "Logger"; "Tag" ] "r")
    ?(payload = Atom.No_payload)
    label =
  Atom.requirement ~declaration ~label ~payload |> get_ok "requirement atom"

let error_leaf ?(materialization = Leaf.Direct) identity members =
  Leaf.error ~identity ~members ~materialization |> get_ok "error leaf"

let requirement_leaf ?(materialization = Leaf.Requirement_tag) identity member =
  Leaf.requirement ~identity ~member ~materialization
  |> get_ok "requirement leaf"

let proof kind leaves =
  Proof.create ~kind ~origin:Proof.Closed_row ~leaves |> get_ok "proof"

let leaf_names leaves =
  List.map (fun leaf -> Identity.declaration_name (Leaf.identity leaf)) leaves

let span () =
  Core.Source_span.make ~file:"example.ml" ~start_offset:10 ~end_offset:24
    ~start_line:2 ~start_column:3 ~end_line:2 ~end_column:17
  |> get_ok "source span"

let marker id kind =
  let id = Core.Marker.id_of_string id |> get_ok "marker id" in
  Core.Marker.make ~id ~kind ~span:(span ())

let check_string_list label expected actual =
  Alcotest.(check (list string)) label expected actual

let test_error_and_requirement_atoms () =
  let payload = Atom.Payload (Type_identity.primitive Type_identity.Int) in
  let error = error_atom ~payload "Read_error" in
  let requirement = requirement_atom ~payload "Logger" in
  Alcotest.(check string)
    "error kind" "error"
    (error |> Atom.kind |> Kind.to_string);
  Alcotest.(check string)
    "requirement kind" "requirement"
    (requirement |> Atom.kind |> Kind.to_string);
  Alcotest.(check int) "error payload arity" 1 (Atom.payload_arity error);
  Alcotest.(check int)
    "requirement payload arity" 1
    (Atom.payload_arity requirement);
  Alcotest.(check bool)
    "channels remain distinct" false
    (Atom.equal_structural error requirement)

let test_nominal_and_structural_identity () =
  let first_declaration =
    identity ~digest:"first" [ "Storage"; "Errors" ] "read_error"
  in
  let second_declaration =
    identity ~digest:"second" [ "Storage"; "Errors" ] "read_error"
  in
  let first = error_atom ~declaration:first_declaration "Read_error" in
  let second = error_atom ~declaration:second_declaration "Read_error" in
  Alcotest.(check bool)
    "nominal identities differ" false (Atom.equal first second);
  Alcotest.(check bool)
    "runtime shapes agree" true
    (Atom.equal_structural first second);
  let payload =
    Type_identity.nominal ~declaration:first_declaration
      ~arguments:[ Type_identity.primitive Type_identity.String ]
  in
  Alcotest.(check string)
    "structured nominal payload" "(string) Storage.Errors.read_error"
    (Type_identity.to_string payload)

let test_overlapping_aliases_refused () =
  let first_identity = identity [ "First"; "Errors" ] "leaf" in
  let second_identity = identity [ "Second"; "Errors" ] "leaf" in
  let first_atom = error_atom ~declaration:first_identity "Shared" in
  let second_atom = error_atom ~declaration:second_identity "Shared" in
  let first = error_leaf first_identity [ first_atom ] in
  let second = error_leaf second_identity [ second_atom ] in
  match
    Proof.create ~kind:Kind.Error ~origin:Proof.Closed_row
      ~leaves:[ first; second ]
  with
  | Error (Proof.Overlapping_atom { atom; _ }) ->
      Alcotest.(check string)
        "overlapping runtime tag" "Shared" (Atom.label atom)
  | _ -> Alcotest.fail "expected overlapping atom refusal"

let test_error_cases_preserves_verified_union () =
  let leaf_id = identity [ "Storage"; "Errors" ] "read_error" in
  let catalogue = identity [ "Storage"; "Errors"; "Cases" ] "t" in
  let union = identity [ "Storage"; "Errors" ] "error" in
  let leaf =
    error_leaf
      ~materialization:
        (Leaf.Error_cases { catalogue; union; field = "read_error" })
      leaf_id
      [ error_atom ~declaration:leaf_id "Read" ]
  in
  match Leaf.materialization leaf with
  | Error_cases { catalogue = actual_catalogue; union = actual_union; field } ->
      Alcotest.(check bool)
        "catalogue identity" true
        (Identity.equal catalogue actual_catalogue);
      Alcotest.(check bool)
        "union identity" true
        (Identity.equal union actual_union);
      Alcotest.(check string) "cases field" "read_error" field
  | _ -> Alcotest.fail "expected error cases materialization"

let test_structural_variant_materialization () =
  let constant_id = identity [ "Current" ] "constant_tag" in
  let payload_id = identity [ "Current" ] "payload_tag" in
  let constant = error_atom ~declaration:constant_id "Constant" in
  let payload =
    error_atom ~declaration:payload_id
      ~payload:(Atom.Payload (Type_identity.primitive Type_identity.Int))
      "Payload"
  in
  let constant_leaf =
    error_leaf ~materialization:Leaf.Structural_variant constant_id [ constant ]
  in
  let payload_leaf =
    error_leaf ~materialization:Leaf.Structural_variant payload_id [ payload ]
  in
  Alcotest.(check int)
    "constant pattern arity" 0
    (constant_leaf |> Leaf.members |> List.hd |> Atom.payload_arity);
  Alcotest.(check int)
    "payload pattern arity" 1
    (payload_leaf |> Leaf.members |> List.hd |> Atom.payload_arity);
  match
    Leaf.error ~identity:constant_id ~members:[ constant; payload ]
      ~materialization:Leaf.Structural_variant
  with
  | Error (Leaf.Invalid_materialization _) -> ()
  | _ -> Alcotest.fail "grouped structural materialization was accepted"

let test_source_span_display_order () =
  match
    Core.Source_span.make ~file:"example.ml" ~start_offset:4 ~end_offset:5
      ~start_line:2 ~start_column:8 ~end_line:2 ~end_column:7
  with
  | Error (Core.Source_span.End_position_before_start _) -> ()
  | _ -> Alcotest.fail "expected invalid display-coordinate order"

let test_error_residual_and_recovery () =
  let a_id = identity [ "Svc"; "Errors" ] "a" in
  let b_id = identity [ "Svc"; "Errors" ] "b" in
  let c_id = identity [ "Recovery"; "Errors" ] "c" in
  let a = error_leaf a_id [ error_atom ~declaration:a_id "A" ] in
  let b = error_leaf b_id [ error_atom ~declaration:b_id "B" ] in
  let c = error_leaf c_id [ error_atom ~declaration:c_id "C" ] in
  let input = proof Kind.Error [ b; a ] in
  let arm =
    Residual.arm ~target:(Complete_leaf a_id) ~guard:Unguarded ~action:Handle
  in
  let result =
    Residual.calculate ~input ~arms:[ arm ] ~recovery:[ c ]
    |> get_ok "error residual"
  in
  check_string_list "handled" [ "a" ] (leaf_names (Residual.handled result));
  check_string_list "recovery" [ "c" ] (leaf_names (Residual.recovery result));
  check_string_list "residual" [ "b" ] (leaf_names (Residual.residual result));
  check_string_list "output" [ "b"; "c" ]
    (leaf_names (Residual.output result) |> List.sort String.compare)

let test_requirement_guard_policy () =
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let clock_id = identity [ "Clock"; "Tag" ] "r" in
  let logger =
    requirement_leaf logger_id
      (requirement_atom ~declaration:logger_id "Logger")
  in
  let clock =
    requirement_leaf clock_id (requirement_atom ~declaration:clock_id "Clock")
  in
  let input = proof Kind.Requirement [ logger; clock ] in
  let guarded_logger =
    Residual.arm ~target:(Complete_leaf logger_id) ~guard:Guarded ~action:Handle
  in
  let give_clock =
    Residual.arm ~target:(Complete_leaf clock_id) ~guard:Unguarded
      ~action:Handle
  in
  let result =
    Residual.calculate ~input ~arms:[ give_clock; guarded_logger ] ~recovery:[]
    |> get_ok "requirement residual"
  in
  check_string_list "only unguarded give handled" [ "r" ]
    (leaf_names (Residual.handled result));
  Alcotest.(check int)
    "one residual requirement" 1
    (List.length (Residual.residual result));
  let residual_identity =
    Residual.residual result |> List.hd |> Leaf.identity
  in
  Alcotest.(check bool)
    "guarded Logger remains" true
    (Identity.equal logger_id residual_identity)

let test_requirement_forwarding () =
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let clock_id = identity [ "Clock"; "Tag" ] "r" in
  let logger =
    requirement_leaf logger_id
      (requirement_atom ~declaration:logger_id "Logger")
  in
  let clock =
    requirement_leaf clock_id (requirement_atom ~declaration:clock_id "Clock")
  in
  let input = proof Kind.Requirement [ logger; clock ] in
  let need_logger =
    Residual.arm ~target:(Complete_leaf logger_id) ~guard:Unguarded
      ~action:Forward
  in
  let result =
    Residual.calculate ~input ~arms:[ need_logger ] ~recovery:[]
    |> get_ok "requirement forward"
  in
  Alcotest.(check int)
    "one explicit forward" 1
    (List.length (Residual.forwarded result));
  Alcotest.(check int)
    "one generated residual" 1
    (List.length (Residual.residual result));
  Alcotest.(check int)
    "both requirements remain in output" 2
    (List.length (Residual.output result))

let test_grouped_leaf_partial_refusal () =
  let group_id = identity [ "Storage"; "Errors" ] "io_error" in
  let read = error_atom ~declaration:group_id "Read" in
  let write = error_atom ~declaration:group_id "Write" in
  let grouped = error_leaf group_id [ write; read ] in
  let input = proof Kind.Error [ grouped ] in
  let partial =
    Residual.arm ~target:(Structural_member read) ~guard:Unguarded
      ~action:Handle
  in
  match Residual.calculate ~input ~arms:[ partial ] ~recovery:[] with
  | Error (Diagnostic.Partially_handled_group { leaf; matched }) ->
      Alcotest.(check bool)
        "group identity preserved" true
        (Identity.equal group_id (Leaf.identity leaf));
      Alcotest.(check int) "one matched group member" 1 (List.length matched)
  | _ -> Alcotest.fail "expected grouped leaf refusal"

let test_linter_observation_stays_incomplete () =
  let declared = Observation.of_tags ~kind:Kind.Error [ "A"; "B"; "B" ] in
  let upstream = Observation.of_tags ~kind:Kind.Error [ "A" ] in
  let candidate =
    Candidate.create ~declared ~upstream |> get_ok "observation candidate"
  in
  check_string_list "historical list-set behavior" [ "B"; "B" ]
    (Candidate.extra candidate);
  let residual = Observation.subtract declared ~handled:[ "A" ] in
  check_string_list "observation residual" [ "B"; "B" ]
    (Observation.tags residual)

let empty_proof kind = proof kind []

let certificate errors requirements =
  Effect_certificate.create
    ~errors:(Effect_certificate.exact errors)
    ~requirements:(Effect_certificate.exact requirements)
  |> get_ok "effect certificate"

let exact_leaves evidence =
  match Effect_certificate.evidence_view evidence with
  | Exact_proof proof -> Proof.leaves proof
  | Opaque_reasons _ -> Alcotest.fail "expected exact channel evidence"

let test_chain_certificate_unions_both_channels () =
  let source_error_id = identity [ "Source"; "Errors" ] "source" in
  let next_error_id = identity [ "Next"; "Errors" ] "next" in
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let clock_id = identity [ "Clock"; "Tag" ] "r" in
  let source =
    certificate
      (proof Kind.Error
         [
           error_leaf source_error_id
             [ error_atom ~declaration:source_error_id "Source_error" ];
         ])
      (proof Kind.Requirement
         [
           requirement_leaf logger_id
             (requirement_atom ~declaration:logger_id "Logger");
         ])
  in
  let next =
    certificate
      (proof Kind.Error
         [
           error_leaf next_error_id
             [ error_atom ~declaration:next_error_id "Next_error" ];
         ])
      (proof Kind.Requirement
         [
           requirement_leaf clock_id
             (requirement_atom ~declaration:clock_id "Clock");
         ])
  in
  let output =
    Effect_certificate.chain ~inputs:[] [ source; next ]
    |> get_ok "chain certificate"
  in
  check_string_list "chain errors" [ "next"; "source" ]
    (output |> Effect_certificate.errors |> exact_leaves |> leaf_names);
  Alcotest.(check int)
    "chain requirements" 2
    (output |> Effect_certificate.requirements |> exact_leaves |> List.length)

let test_recover_certificate_replaces_errors_and_unions_requirements () =
  let source_error_id = identity [ "Source"; "Errors" ] "source" in
  let recovery_error_id = identity [ "Recovery"; "Errors" ] "recovery" in
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let clock_id = identity [ "Clock"; "Tag" ] "r" in
  let source =
    certificate
      (proof Kind.Error
         [
           error_leaf source_error_id
             [ error_atom ~declaration:source_error_id "Source_error" ];
         ])
      (proof Kind.Requirement
         [
           requirement_leaf logger_id
             (requirement_atom ~declaration:logger_id "Logger");
         ])
  in
  let recovery =
    certificate
      (proof Kind.Error
         [
           error_leaf recovery_error_id
             [ error_atom ~declaration:recovery_error_id "Recovery_error" ];
         ])
      (proof Kind.Requirement
         [
           requirement_leaf clock_id
             (requirement_atom ~declaration:clock_id "Clock");
         ])
  in
  let output =
    Effect_certificate.recover ~inputs:[] ~source ~recoveries:[ recovery ]
    |> get_ok "recover certificate"
  in
  check_string_list "recover replaces source errors" [ "recovery" ]
    (output |> Effect_certificate.errors |> exact_leaves |> leaf_names);
  Alcotest.(check int)
    "recover unions requirements" 2
    (output |> Effect_certificate.requirements |> exact_leaves |> List.length)

let test_catch_certificate_unions_recovery_requirements () =
  let source_error_id = identity [ "Source"; "Errors" ] "source" in
  let recovery_error_id = identity [ "Recovery"; "Errors" ] "recovery" in
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let source_error =
    error_leaf source_error_id
      [ error_atom ~declaration:source_error_id "Source_error" ]
  in
  let recovery_error =
    error_leaf recovery_error_id
      [ error_atom ~declaration:recovery_error_id "Recovery_error" ]
  in
  let logger =
    requirement_leaf logger_id
      (requirement_atom ~declaration:logger_id "Logger")
  in
  let source_errors = proof Kind.Error [ source_error ] in
  let source = certificate source_errors (empty_proof Kind.Requirement) in
  let recovery =
    certificate
      (proof Kind.Error [ recovery_error ])
      (proof Kind.Requirement [ logger ])
  in
  let arm =
    Residual.arm ~target:(Complete_leaf source_error_id) ~guard:Unguarded
      ~action:Handle
  in
  let error_result =
    Residual.calculate ~input:source_errors ~arms:[ arm ]
      ~recovery:[ recovery_error ]
    |> get_ok "catch residual"
  in
  let output =
    Effect_certificate.catch ~inputs:[] ~source ~error_result
      ~recoveries:[ recovery ]
    |> get_ok "catch certificate"
  in
  check_string_list "recovery error survives" [ "recovery" ]
    (output |> Effect_certificate.errors |> exact_leaves |> leaf_names);
  Alcotest.(check int)
    "recovery requirement survives" 1
    (output |> Effect_certificate.requirements |> exact_leaves |> List.length)

let test_provide_certificate_unions_handler_errors () =
  let source_error_id = identity [ "Source"; "Errors" ] "source" in
  let handler_error_id = identity [ "Handler"; "Errors" ] "handler" in
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let source_error =
    error_leaf source_error_id
      [ error_atom ~declaration:source_error_id "Source_error" ]
  in
  let handler_error =
    error_leaf handler_error_id
      [ error_atom ~declaration:handler_error_id "Handler_error" ]
  in
  let logger =
    requirement_leaf logger_id
      (requirement_atom ~declaration:logger_id "Logger")
  in
  let source_requirements = proof Kind.Requirement [ logger ] in
  let source =
    certificate (proof Kind.Error [ source_error ]) source_requirements
  in
  let handler =
    certificate
      (proof Kind.Error [ handler_error ])
      (empty_proof Kind.Requirement)
  in
  let arm =
    Residual.arm ~target:(Complete_leaf logger_id) ~guard:Unguarded
      ~action:Handle
  in
  let requirement_result =
    Residual.calculate ~input:source_requirements ~arms:[ arm ] ~recovery:[]
    |> get_ok "provide residual"
  in
  let output =
    Effect_certificate.provide ~inputs:[] ~source ~requirement_result
      ~handlers:[ handler ]
    |> get_ok "provide certificate"
  in
  check_string_list "source and handler errors survive" [ "handler"; "source" ]
    (output |> Effect_certificate.errors |> exact_leaves |> leaf_names);
  Alcotest.(check int)
    "provided requirement removed" 0
    (output |> Effect_certificate.requirements |> exact_leaves |> List.length)

let test_opaque_recovery_blocks_downstream_error_proof () =
  let source_error_id = identity [ "Source"; "Errors" ] "source" in
  let source_error =
    error_leaf source_error_id
      [ error_atom ~declaration:source_error_id "Source_error" ]
  in
  let source_errors = proof Kind.Error [ source_error ] in
  let source = certificate source_errors (empty_proof Kind.Requirement) in
  let recovery =
    Effect_certificate.create
      ~errors:(Effect_certificate.opaque Unproven_origin)
      ~requirements:(Effect_certificate.exact (empty_proof Kind.Requirement))
    |> get_ok "opaque recovery"
  in
  let arm =
    Residual.arm ~target:(Complete_leaf source_error_id) ~guard:Unguarded
      ~action:Handle
  in
  let error_result =
    Residual.calculate ~input:source_errors ~arms:[ arm ] ~recovery:[]
    |> get_ok "opaque recovery residual"
  in
  let output =
    Effect_certificate.catch ~inputs:[] ~source ~error_result
      ~recoveries:[ recovery ]
    |> get_ok "opaque catch certificate"
  in
  Alcotest.(check int)
    "unaffected requirements remain exact" 0
    (output |> Effect_certificate.requirements |> exact_leaves |> List.length);
  match
    output |> Effect_certificate.errors |> Effect_certificate.evidence_view
  with
  | Opaque_reasons reasons ->
      Alcotest.(check bool)
        "role-specific opacity" true
        (List.mem Effect_certificate.Opaque_recovery reasons)
  | Exact_proof _ ->
      Alcotest.fail "opaque recovery produced an exact error proof"

let test_opaque_handler_only_blocks_requirement_proof () =
  let logger_id = identity [ "Logger"; "Tag" ] "r" in
  let handler_error_id = identity [ "Handler"; "Errors" ] "handler" in
  let logger =
    requirement_leaf logger_id
      (requirement_atom ~declaration:logger_id "Logger")
  in
  let handler_error =
    error_leaf handler_error_id
      [ error_atom ~declaration:handler_error_id "Handler_error" ]
  in
  let source_requirements = proof Kind.Requirement [ logger ] in
  let source = certificate (empty_proof Kind.Error) source_requirements in
  let handler =
    Effect_certificate.create
      ~errors:(Effect_certificate.exact (proof Kind.Error [ handler_error ]))
      ~requirements:(Effect_certificate.opaque Unproven_origin)
    |> get_ok "opaque handler"
  in
  let arm =
    Residual.arm ~target:(Complete_leaf logger_id) ~guard:Unguarded
      ~action:Handle
  in
  let requirement_result =
    Residual.calculate ~input:source_requirements ~arms:[ arm ] ~recovery:[]
    |> get_ok "opaque handler residual"
  in
  let output =
    Effect_certificate.provide ~inputs:[] ~source ~requirement_result
      ~handlers:[ handler ]
    |> get_ok "opaque provide certificate"
  in
  check_string_list "unaffected errors remain exact" [ "handler" ]
    (output |> Effect_certificate.errors |> exact_leaves |> leaf_names);
  match
    output
    |> Effect_certificate.requirements
    |> Effect_certificate.evidence_view
  with
  | Opaque_reasons reasons ->
      Alcotest.(check bool)
        "handler opacity is classified" true
        (List.mem Effect_certificate.Opaque_handler reasons)
  | Exact_proof _ ->
      Alcotest.fail "opaque handler produced an exact requirement proof"

let test_contributor_mismatch_is_rejected () =
  let source_id = identity [ "Source"; "Errors" ] "source" in
  let recovery_id = identity [ "Recovery"; "Errors" ] "recovery" in
  let source_leaf =
    error_leaf source_id [ error_atom ~declaration:source_id "Source_error" ]
  in
  let recovery_leaf =
    error_leaf recovery_id
      [ error_atom ~declaration:recovery_id "Recovery_error" ]
  in
  let source_errors = proof Kind.Error [ source_leaf ] in
  let source = certificate source_errors (empty_proof Kind.Requirement) in
  let recovery =
    certificate
      (proof Kind.Error [ recovery_leaf ])
      (empty_proof Kind.Requirement)
  in
  let arm =
    Residual.arm ~target:(Complete_leaf source_id) ~guard:Unguarded
      ~action:Handle
  in
  let error_result =
    Residual.calculate ~input:source_errors ~arms:[ arm ] ~recovery:[]
    |> get_ok "mismatched residual"
  in
  match
    Effect_certificate.catch ~inputs:[] ~source ~error_result
      ~recoveries:[ recovery ]
  with
  | Error (Effect_certificate.Contributing_proof_mismatch Kind.Error) -> ()
  | _ -> Alcotest.fail "expected contributor mismatch"

let calculation_for marker_id =
  let leaf_id = identity [ "Storage"; "Errors" ] "read_error" in
  let payload_id = identity [ "Storage"; "Errors" ] "write_error" in
  let leaf =
    error_leaf ~materialization:Leaf.Structural_variant leaf_id
      [ error_atom ~declaration:leaf_id "Read" ]
  in
  let payload_leaf =
    error_leaf ~materialization:Leaf.Structural_variant payload_id
      [
        error_atom ~declaration:payload_id
          ~payload:(Atom.Payload (Type_identity.primitive Type_identity.String))
          "Write";
      ]
  in
  let input = proof Kind.Error [ payload_leaf; leaf ] in
  let calculation =
    Residual.calculate ~input ~arms:[] ~recovery:[]
    |> get_ok "protocol residual"
  in
  let marker = marker marker_id Kind.Error in
  let resolution_certificate =
    certificate
      (proof Kind.Error (Residual.output calculation))
      (empty_proof Kind.Requirement)
  in
  let result =
    Protocol.marker_result ~marker ~outcome:(Resolved calculation)
      ~certificate:(Some resolution_certificate)
    |> get_ok "protocol marker result"
  in
  (marker, result)

let test_protocol_round_trip () =
  let _, result = calculation_for "marker-a" in
  let response =
    Protocol.response ~request_id:"request-1" ~context_fingerprint:"context-1"
      ~ast_digest:"ast-1" [ result ]
    |> get_ok "protocol response"
  in
  let encoded = Protocol.encode response in
  let decoded = Protocol.decode encoded |> get_ok "protocol decode" in
  Alcotest.(check bool) "round trip" true (Protocol.equal response decoded);
  Alcotest.(check string)
    "canonical re-encode" encoded (Protocol.encode decoded)

let test_protocol_catalogue_round_trip_and_validation () =
  let catalogue_identity = identity [ "Storage"; "Errors"; "Cases" ] "t" in
  let union = identity [ "Storage"; "Errors" ] "error" in
  let read = identity [ "Storage"; "Errors" ] "read_error" in
  let write = identity [ "Storage"; "Errors" ] "write_error" in
  let catalogue =
    Protocol.catalogue ~identity:catalogue_identity ~union
      ~fields:[ ("read_error", read); ("write_error", write) ]
    |> get_ok "protocol catalogue"
  in
  let response =
    Protocol.response ~catalogues:[ catalogue; catalogue ]
      ~request_id:"catalogue-request" ~context_fingerprint:"catalogue-context"
      ~ast_digest:"catalogue-ast" []
    |> get_ok "catalogue response"
  in
  Alcotest.(check int)
    "duplicate evidence normalized" 1
    (List.length (Protocol.catalogues response));
  let decoded = Protocol.decode (Protocol.encode response) |> get_ok "decode" in
  Alcotest.(check bool)
    "catalogue round trip" true
    (Protocol.equal response decoded);
  let fields =
    Protocol.catalogues decoded
    |> List.hd
    |> Protocol.catalogue_fields
    |> List.map fst
  in
  check_string_list "declaration field order"
    [ "read_error"; "write_error" ]
    fields;
  let conflicting =
    Protocol.catalogue ~identity:catalogue_identity ~union:read
      ~fields:[ ("read_error", read) ]
    |> get_ok "conflicting catalogue"
  in
  (match
     Protocol.response ~catalogues:[ catalogue; conflicting ]
       ~request_id:"catalogue-request" ~context_fingerprint:"catalogue-context"
       ~ast_digest:"catalogue-ast" []
   with
  | Error (Protocol.Conflicting_catalogue actual) ->
      Alcotest.(check bool)
        "conflicting identity" true
        (Identity.equal catalogue_identity actual)
  | _ -> Alcotest.fail "expected conflicting catalogue refusal");
  match
    Protocol.catalogue ~identity:catalogue_identity ~union
      ~fields:[ ("same", read); ("same", write) ]
  with
  | Error (Protocol.Duplicate_catalogue_field_name _) -> ()
  | _ -> Alcotest.fail "expected duplicate catalogue field refusal"

let test_refusal_round_trip () =
  let marker = marker "marker-refused" Kind.Requirement in
  let diagnostic = Diagnostic.make ~marker ~code:Diagnostic.Open_row in
  let result =
    Protocol.marker_result ~marker ~outcome:(Refused diagnostic)
      ~certificate:None
    |> get_ok "refused marker result"
  in
  let response =
    Protocol.response ~request_id:"request-2" ~context_fingerprint:"context-2"
      ~ast_digest:"ast-2" [ result ]
    |> get_ok "refused response"
  in
  let decoded = Protocol.decode (Protocol.encode response) |> get_ok "decode" in
  Alcotest.(check bool)
    "refusal round trip" true
    (Protocol.equal response decoded)

let test_actionable_refusal_codes_round_trip () =
  let marker = marker "marker-actionable" Kind.Requirement in
  let codes =
    [
      Diagnostic.Invalid_owner;
      Diagnostic.Invalid_error_catalogue "missing field";
      Diagnostic.Unsupported_handler_rhs;
    ]
  in
  List.iter
    (fun code ->
      let diagnostic = Diagnostic.make ~marker ~code in
      let result =
        Protocol.marker_result ~marker ~outcome:(Refused diagnostic)
          ~certificate:None
        |> get_ok "actionable result"
      in
      let response =
        Protocol.response ~request_id:"actionable-request"
          ~context_fingerprint:"actionable" ~ast_digest:"actionable-ast"
          [ result ]
        |> get_ok "actionable response"
      in
      let decoded =
        Protocol.decode (Protocol.encode response) |> get_ok "actionable decode"
      in
      Alcotest.(check bool)
        "actionable refusal round trip" true
        (Protocol.equal response decoded))
    codes

let test_protocol_version_mismatch () =
  match
    Protocol.decode {|{"protocol":"hamlet-subtractor-resolution","version":99}|}
  with
  | Error (Protocol.Version_mismatch { expected = 5; actual = 99 }) -> ()
  | _ -> Alcotest.fail "expected protocol version mismatch"

let test_protocol_malformed_payload () =
  match Protocol.decode "not json" with
  | Error (Protocol.Malformed _) -> ()
  | _ -> Alcotest.fail "expected malformed protocol payload"

let test_tag_only_payload_is_not_exact_proof () =
  let payload =
    {|{"protocol":"hamlet-subtractor-resolution","version":5,"request_id":"r","context_fingerprint":"ctx","ast_digest":"ast","results":[{"marker":{"id":"m","kind":"error","span":{"file":"x.ml","start_offset":0,"end_offset":1,"start_line":1,"start_column":0,"end_line":1,"end_column":1}},"outcome":{"kind":"resolved","calculation":{"input":{"kind":"error","origin":{"kind":"closed_row"},"leaves":[{"kind":"error","members":["A"],"materialization":{"kind":"direct"}}]},"arms":[],"recovery":[]}},"certificate":null}],"catalogues":[]}|}
  in
  match Protocol.decode payload with
  | Error (Protocol.Malformed _) -> ()
  | _ -> Alcotest.fail "tag-only observation decoded as an exact proof"

let test_deterministic_serialization () =
  let _, first = calculation_for "marker-b" in
  let _, second = calculation_for "marker-a" in
  let left =
    Protocol.response ~request_id:"deterministic" ~context_fingerprint:"context"
      ~ast_digest:"ast" [ first; second ]
    |> get_ok "left response"
  in
  let right =
    Protocol.response ~request_id:"deterministic" ~context_fingerprint:"context"
      ~ast_digest:"ast" [ second; first ]
    |> get_ok "right response"
  in
  Alcotest.(check string)
    "result ordering is canonical" (Protocol.encode left)
    (Protocol.encode right)

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
    principal = true;
    recursive_types = false;
    alias_dependencies = true;
    use_threads = true;
    unboxed_types = true;
  }

let request expected_markers context_fingerprint =
  let probe_ast =
    Protocol.
      {
        path = "/tmp/hamlet-subtractor-test.ast";
        input_name = "src/example.ml";
        magic = "Caml1999M999";
        digest = "request-ast";
        byte_length = 32;
      }
  in
  Protocol.request ~request_id:"request-id" ~source_file:"src/example.ml"
    ~tool_name:"ocamlopt" ~probe_ast
    ~probe_unit:(Protocol.Synthetic_unit "Hamlet_subtractor_probe_test")
    ~tool_context ~context_fingerprint ~include_dirs:[ "src" ]
    ~hidden_include_dirs:[ "private" ]
    ~visible_paths:[ "_build/default/lib"; "/stdlib" ]
    ~hidden_paths:[ "_build/default/.private" ]
    ~opens:[ "Hamlet" ] ~package_mode:(For_pack "Example_pack") ~compiler_flags
    ~expected_markers

let test_request_round_trip () =
  let first = marker "marker-b" Kind.Error in
  let second = marker "marker-a" Kind.Requirement in
  let request =
    request [ first; second ] "request-context" |> get_ok "request"
  in
  let encoded = Protocol.encode_request request in
  let decoded = Protocol.decode_request encoded |> get_ok "decode request" in
  Alcotest.(check bool)
    "request round trip" true
    (Protocol.equal_request request decoded);
  Alcotest.(check string)
    "canonical request re-encode" encoded
    (Protocol.encode_request decoded);
  check_string_list "marker set is sorted" [ "marker-a"; "marker-b" ]
    (Protocol.expected_markers request
    |> List.map (fun marker ->
        marker |> Core.Marker.id |> Core.Marker.id_to_string))

let test_request_version_mismatch () =
  match
    Protocol.decode_request
      {|{"protocol":"hamlet-subtractor-request","version":42}|}
  with
  | Error (Protocol.Version_mismatch { expected = 5; actual = 42 }) -> ()
  | _ -> Alcotest.fail "expected request version mismatch"

let test_request_malformed () =
  match
    Protocol.decode_request {|{"protocol":"hamlet-subtractor-request"}|}
  with
  | Error (Protocol.Malformed _) -> ()
  | _ -> Alcotest.fail "expected malformed request"

let test_request_rejects_empty_fingerprint () =
  match request [ marker "m" Kind.Error ] "" with
  | Error Protocol.Empty_context_fingerprint -> ()
  | _ -> Alcotest.fail "expected empty context fingerprint refusal"

let test_request_rejects_duplicate_marker () =
  let marker = marker "same" Kind.Error in
  match request [ marker; marker ] "context" with
  | Error (Protocol.Duplicate_marker _) -> ()
  | _ -> Alcotest.fail "expected duplicate marker refusal"

let test_request_response_fingerprint_correlation () =
  let marker, result = calculation_for "marker-a" in
  let request = request [ marker ] "expected-context" |> get_ok "request" in
  let response =
    Protocol.response ~request_id:"request-id"
      ~context_fingerprint:"actual-context" ~ast_digest:"request-ast" [ result ]
    |> get_ok "response"
  in
  match Protocol.validate_response ~request ~response with
  | Error
      (Protocol.Context_fingerprint_mismatch
         { expected = "expected-context"; actual = "actual-context" }) ->
      ()
  | _ -> Alcotest.fail "expected context fingerprint mismatch"

let test_request_response_marker_metadata_correlation () =
  let expected, result = calculation_for "marker-metadata" in
  let request = request [ expected ] "marker-context" |> get_ok "request" in
  let altered_span =
    Core.Source_span.make ~file:"different.ml" ~start_offset:1 ~end_offset:2
      ~start_line:1 ~start_column:1 ~end_line:1 ~end_column:2
    |> get_ok "altered span"
  in
  let altered =
    Core.Marker.make ~id:(Core.Marker.id expected)
      ~kind:(Core.Marker.kind expected)
      ~span:altered_span
  in
  let altered_result =
    Protocol.marker_result ~marker:altered ~outcome:(Protocol.outcome result)
      ~certificate:(Protocol.certificate result)
    |> get_ok "altered result"
  in
  let response =
    Protocol.response ~request_id:"request-id"
      ~context_fingerprint:"marker-context" ~ast_digest:"request-ast"
      [ altered_result ]
    |> get_ok "response"
  in
  match Protocol.validate_response ~request ~response with
  | Error (Protocol.Marker_mismatch { expected = actual_expected; actual }) ->
      Alcotest.(check bool)
        "expected marker retained" true
        (Core.Marker.equal expected actual_expected);
      Alcotest.(check bool)
        "altered marker rejected" false
        (Core.Marker.equal expected actual)
  | _ -> Alcotest.fail "expected marker metadata mismatch"

let () =
  Alcotest.run "hamlet-subtractor-core"
    [
      ( "identity",
        [
          Alcotest.test_case "error and requirement atoms" `Quick
            test_error_and_requirement_atoms;
          Alcotest.test_case "nominal and structural identity" `Quick
            test_nominal_and_structural_identity;
          Alcotest.test_case "overlapping aliases refused" `Quick
            test_overlapping_aliases_refused;
          Alcotest.test_case "error cases union identity" `Quick
            test_error_cases_preserves_verified_union;
          Alcotest.test_case "structural variant materialization" `Quick
            test_structural_variant_materialization;
          Alcotest.test_case "source span coordinate order" `Quick
            test_source_span_display_order;
        ] );
      ( "residual",
        [
          Alcotest.test_case "error recovery union" `Quick
            test_error_residual_and_recovery;
          Alcotest.test_case "guarded give does not subtract" `Quick
            test_requirement_guard_policy;
          Alcotest.test_case "need forwards requirement" `Quick
            test_requirement_forwarding;
          Alcotest.test_case "grouped partial refusal" `Quick
            test_grouped_leaf_partial_refusal;
          Alcotest.test_case "linter observation is incomplete" `Quick
            test_linter_observation_stays_incomplete;
          Alcotest.test_case "catch recovery requirements" `Quick
            test_catch_certificate_unions_recovery_requirements;
          Alcotest.test_case "chain unions both channels" `Quick
            test_chain_certificate_unions_both_channels;
          Alcotest.test_case "recover replaces errors" `Quick
            test_recover_certificate_replaces_errors_and_unions_requirements;
          Alcotest.test_case "provide handler errors" `Quick
            test_provide_certificate_unions_handler_errors;
          Alcotest.test_case "opaque recovery blocks proof" `Quick
            test_opaque_recovery_blocks_downstream_error_proof;
          Alcotest.test_case "opaque handler blocks requirement proof" `Quick
            test_opaque_handler_only_blocks_requirement_proof;
          Alcotest.test_case "contributor mismatch" `Quick
            test_contributor_mismatch_is_rejected;
        ] );
      ( "protocol",
        [
          Alcotest.test_case "resolved round trip" `Quick
            test_protocol_round_trip;
          Alcotest.test_case "catalogue round trip" `Quick
            test_protocol_catalogue_round_trip_and_validation;
          Alcotest.test_case "refusal round trip" `Quick test_refusal_round_trip;
          Alcotest.test_case "actionable refusal codes" `Quick
            test_actionable_refusal_codes_round_trip;
          Alcotest.test_case "version mismatch" `Quick
            test_protocol_version_mismatch;
          Alcotest.test_case "malformed payload" `Quick
            test_protocol_malformed_payload;
          Alcotest.test_case "tag-only input rejected" `Quick
            test_tag_only_payload_is_not_exact_proof;
          Alcotest.test_case "deterministic serialization" `Quick
            test_deterministic_serialization;
          Alcotest.test_case "request round trip" `Quick test_request_round_trip;
          Alcotest.test_case "request version mismatch" `Quick
            test_request_version_mismatch;
          Alcotest.test_case "request malformed" `Quick test_request_malformed;
          Alcotest.test_case "request fingerprint required" `Quick
            test_request_rejects_empty_fingerprint;
          Alcotest.test_case "request markers unique" `Quick
            test_request_rejects_duplicate_marker;
          Alcotest.test_case "request response fingerprint" `Quick
            test_request_response_fingerprint_correlation;
          Alcotest.test_case "request response marker metadata" `Quick
            test_request_response_marker_metadata_correlation;
        ] );
    ]
