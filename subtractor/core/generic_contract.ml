let schema_version = 2
let max_encoded_bytes = 1_048_576
let max_slots = 256
let max_expression_depth = 64
let max_expression_nodes = 16_384
let max_leaves = 4_096

type channel_expression =
  | Input_expression of Kind.t
  | Evidence_expression of {
      kind : Kind.t;
      evidence : Effect_certificate.evidence;
    }
  | Union_expression of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      terms : channel_expression list;
    }
  | Subtract_expression of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      source : channel_expression;
      handled : Leaf.t list;
      explicitly_forwarded : Leaf.t list;
      recovery : channel_expression;
    }

type expression_view =
  | Input of Kind.t
  | Evidence of { kind : Kind.t; evidence : Effect_certificate.evidence }
  | Union of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      terms : channel_expression list;
    }
  | Subtract of {
      kind : Kind.t;
      operation : Proof.composition;
      inputs : Marker.id list;
      source : channel_expression;
      handled : Leaf.t list;
      explicitly_forwarded : Leaf.t list;
      recovery : channel_expression;
    }

type expression_error =
  | Empty_union
  | Wrong_expression_kind of { expected : Kind.t; actual : Kind.t }
  | Wrong_leaf_kind of { leaf : Identity.t; expected : Kind.t; actual : Kind.t }
  | Duplicate_leaf of Identity.t
  | Conflicting_partition_leaf of Identity.t
  | Partition_leaf_not_claimed of Identity.t

let expression_kind = function
  | Input_expression kind
  | Evidence_expression { kind; _ }
  | Union_expression { kind; _ }
  | Subtract_expression { kind; _ } ->
      kind

let expression_view = function
  | Input_expression kind -> Input kind
  | Evidence_expression { kind; evidence } -> Evidence { kind; evidence }
  | Union_expression { kind; operation; inputs; terms } ->
      Union { kind; operation; inputs; terms }
  | Subtract_expression
      {
        kind;
        operation;
        inputs;
        source;
        handled;
        explicitly_forwarded;
        recovery;
      } ->
      Subtract
        {
          kind;
          operation;
          inputs;
          source;
          handled;
          explicitly_forwarded;
          recovery;
        }

let compare_expression = Stdlib.compare
let equal_expression first second = compare_expression first second = 0
let input kind = Input_expression kind

let exact proof =
  Evidence_expression
    { kind = Proof.kind proof; evidence = Effect_certificate.exact proof }

let normalize_opacity = function
  | [] -> [ Effect_certificate.Unproven_origin ]
  | reasons -> List.sort_uniq Stdlib.compare reasons

let opaque kind reasons =
  let reasons = normalize_opacity reasons in
  match Effect_certificate.opaque_many reasons with
  | Some evidence -> Evidence_expression { kind; evidence }
  | None -> assert false

let validate_expression_kind expected expression =
  let actual = expression_kind expression in
  if Kind.equal expected actual then Ok ()
  else Error (Wrong_expression_kind { expected; actual })

let validate_leaf_kinds expected leaves =
  match
    List.find_opt
      (fun leaf -> not (Kind.equal expected (Leaf.kind leaf)))
      leaves
  with
  | None -> Ok ()
  | Some leaf ->
      Error
        (Wrong_leaf_kind
           { leaf = Leaf.identity leaf; expected; actual = Leaf.kind leaf })

let normalize_leaves leaves =
  List.sort
    (fun first second ->
      Identity.compare (Leaf.identity first) (Leaf.identity second))
    leaves

let validate_unique_leaves leaves =
  let rec loop = function
    | first :: second :: _
      when Identity.equal (Leaf.identity first) (Leaf.identity second) ->
        Error (Duplicate_leaf (Leaf.identity first))
    | _ :: rest -> loop rest
    | [] -> Ok ()
  in
  loop leaves

let normalize_partition kind handled explicitly_forwarded =
  match validate_leaf_kinds kind handled with
  | Error _ as error -> error
  | Ok () -> (
      match validate_leaf_kinds kind explicitly_forwarded with
      | Error _ as error -> error
      | Ok () ->
          let handled = normalize_leaves handled in
          let explicitly_forwarded = normalize_leaves explicitly_forwarded in
          begin match validate_unique_leaves handled with
          | Error _ as error -> error
          | Ok () -> (
              match validate_unique_leaves explicitly_forwarded with
              | Error _ as error -> error
              | Ok () -> (
                  let conflict =
                    List.find_opt
                      (fun handled_leaf ->
                        List.exists
                          (fun forwarded_leaf ->
                            Identity.equal
                              (Leaf.identity handled_leaf)
                              (Leaf.identity forwarded_leaf))
                          explicitly_forwarded)
                      handled
                  in
                  match conflict with
                  | Some leaf ->
                      Error (Conflicting_partition_leaf (Leaf.identity leaf))
                  | None -> Ok (handled, explicitly_forwarded)))
          end)

let union ~kind ~operation ~inputs terms =
  match terms with
  | [] -> Error Empty_union
  | terms ->
      let rec validate = function
        | [] -> Ok ()
        | term :: rest -> (
            match validate_expression_kind kind term with
            | Error _ as error -> error
            | Ok () -> validate rest)
      in
      begin match validate terms with
      | Error _ as error -> error
      | Ok () ->
          Ok
            (Union_expression
               {
                 kind;
                 operation;
                 inputs = List.sort_uniq Marker.compare_id inputs;
                 terms = List.sort_uniq compare_expression terms;
               })
      end

let subtract ~operation ~inputs ~source ~handled ~explicitly_forwarded ~recovery
    =
  let kind = expression_kind source in
  match validate_expression_kind kind recovery with
  | Error _ as error -> error
  | Ok () -> (
      match normalize_partition kind handled explicitly_forwarded with
      | Error _ as error -> error
      | Ok (handled, explicitly_forwarded) ->
          Ok
            (Subtract_expression
               {
                 kind;
                 operation;
                 inputs = List.sort_uniq Marker.compare_id inputs;
                 source;
                 handled;
                 explicitly_forwarded;
                 recovery;
               }))

let empty_proof kind =
  match Proof.create ~kind ~origin:Proof.Closed_row ~leaves:[] with
  | Ok proof -> proof
  | Error _ -> assert false

let clear kind = exact (empty_proof kind)

type symbolic_certificate = {
  errors : channel_expression;
  requirements : channel_expression;
}

let certificate ~errors ~requirements =
  match validate_expression_kind Kind.Error errors with
  | Error _ as error -> error
  | Ok () -> (
      match validate_expression_kind Kind.Requirement requirements with
      | Error _ as error -> error
      | Ok () -> Ok { errors; requirements })

let input_certificate =
  { errors = input Kind.Error; requirements = input Kind.Requirement }

let concrete certificate =
  let expression kind evidence = Evidence_expression { kind; evidence } in
  {
    errors = expression Kind.Error (Effect_certificate.errors certificate);
    requirements =
      expression Kind.Requirement (Effect_certificate.requirements certificate);
  }

let errors certificate = certificate.errors
let requirements certificate = certificate.requirements

let union_or_clear ~kind ~operation ~inputs expressions =
  match expressions with
  | [] -> Ok (clear kind)
  | expressions -> union ~kind ~operation ~inputs expressions

let chain ~inputs certificates =
  let error_terms = List.map errors certificates in
  let requirement_terms = List.map requirements certificates in
  match
    union_or_clear ~kind:Kind.Error ~operation:Proof.Chain ~inputs error_terms
  with
  | Error _ as error -> error
  | Ok errors -> (
      match
        union_or_clear ~kind:Kind.Requirement ~operation:Proof.Chain ~inputs
          requirement_terms
      with
      | Error _ as error -> error
      | Ok requirements -> Ok { errors; requirements })

let catch ~inputs ~source ~handled ~explicitly_forwarded ~recoveries =
  let recovery_errors = List.map errors recoveries in
  let recovery_requirements = List.map requirements recoveries in
  match
    union_or_clear ~kind:Kind.Error ~operation:Proof.Catch ~inputs
      recovery_errors
  with
  | Error _ as error -> error
  | Ok recovery -> (
      match
        subtract ~operation:Proof.Catch ~inputs ~source:source.errors ~handled
          ~explicitly_forwarded ~recovery
      with
      | Error _ as error -> error
      | Ok errors -> (
          match
            union ~kind:Kind.Requirement ~operation:Proof.Catch ~inputs
              (source.requirements :: recovery_requirements)
          with
          | Error _ as error -> error
          | Ok requirements -> Ok { errors; requirements }))

let provide ~inputs ~source ~handled ~explicitly_forwarded ~handlers =
  let handler_errors = List.map errors handlers in
  let handler_requirements = List.map requirements handlers in
  match
    union_or_clear ~kind:Kind.Requirement ~operation:Proof.Provide ~inputs
      handler_requirements
  with
  | Error _ as error -> error
  | Ok recovery -> (
      match
        subtract ~operation:Proof.Provide ~inputs ~source:source.requirements
          ~handled ~explicitly_forwarded ~recovery
      with
      | Error _ as error -> error
      | Ok requirements -> (
          match
            union ~kind:Kind.Error ~operation:Proof.Provide ~inputs
              (source.errors :: handler_errors)
          with
          | Error _ as error -> error
          | Ok errors -> Ok { errors; requirements }))

let with_errors ~source ~errors =
  certificate ~errors ~requirements:source.requirements

let with_requirements ~source ~requirements =
  certificate ~errors:source.errors ~requirements

let rec substitute_expression ~input:replacement expression =
  match expression with
  | Input_expression Kind.Error -> replacement.errors
  | Input_expression Kind.Requirement -> replacement.requirements
  | Evidence_expression _ -> expression
  | Union_expression row ->
      let terms =
        List.map (substitute_expression ~input:replacement) row.terms
      in
      begin match
        union ~kind:row.kind ~operation:row.operation ~inputs:row.inputs terms
      with
      | Ok expression -> expression
      | Error _ -> assert false
      end
  | Subtract_expression row ->
      Subtract_expression
        {
          row with
          source = substitute_expression ~input:replacement row.source;
          recovery = substitute_expression ~input:replacement row.recovery;
        }

let substitute ~input certificate =
  {
    errors = substitute_expression ~input certificate.errors;
    requirements = substitute_expression ~input certificate.requirements;
  }

type slot_id = string

type slot = {
  id : slot_id;
  ordinal : int;
  kind : Kind.t;
  input : channel_expression;
  claimed : Leaf.t list;
  handled : Leaf.t list;
  explicitly_forwarded : Leaf.t list;
  recovery : channel_expression;
}

type slot_error =
  | Empty_slot_id
  | Slot_id_has_surrounding_whitespace
  | Negative_slot_ordinal of int
  | Slot_expression_error of expression_error

let slot_id value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then Error Empty_slot_id
  else if not (String.equal trimmed value) then
    Error Slot_id_has_surrounding_whitespace
  else Ok value

let slot_id_to_string id = id

let claimed_contains claimed leaf =
  List.exists (fun candidate -> Leaf.equal candidate leaf) claimed

let validate_partition_subset ~claimed leaves =
  match
    List.find_opt (fun leaf -> not (claimed_contains claimed leaf)) leaves
  with
  | None -> Ok ()
  | Some leaf -> Error (Partition_leaf_not_claimed (Leaf.identity leaf))

let normalize_claimed kind claimed =
  match validate_leaf_kinds kind claimed with
  | Error _ as error -> error
  | Ok () ->
      let claimed = normalize_leaves claimed in
      Result.map (fun () -> claimed) (validate_unique_leaves claimed)

let slot
    ~id
    ~ordinal
    ~kind
    ~input
    ~claimed
    ~handled
    ~explicitly_forwarded
    ~recovery =
  if ordinal < 0 then Error (Negative_slot_ordinal ordinal)
  else
    match validate_expression_kind kind input with
    | Error error -> Error (Slot_expression_error error)
    | Ok () -> (
        match validate_expression_kind kind recovery with
        | Error error -> Error (Slot_expression_error error)
        | Ok () -> (
            match normalize_claimed kind claimed with
            | Error error -> Error (Slot_expression_error error)
            | Ok claimed -> (
                match normalize_partition kind handled explicitly_forwarded with
                | Error error -> Error (Slot_expression_error error)
                | Ok (handled, explicitly_forwarded) -> (
                    match validate_partition_subset ~claimed handled with
                    | Error error -> Error (Slot_expression_error error)
                    | Ok () -> (
                        match
                          validate_partition_subset ~claimed
                            explicitly_forwarded
                        with
                        | Error error -> Error (Slot_expression_error error)
                        | Ok () ->
                            Ok
                              {
                                id;
                                ordinal;
                                kind;
                                input;
                                claimed;
                                handled;
                                explicitly_forwarded;
                                recovery;
                              })))))

let slot_id_value slot = slot.id
let slot_ordinal slot = slot.ordinal
let slot_kind slot = slot.kind
let slot_input slot = slot.input
let slot_claimed slot = slot.claimed
let slot_handled slot = slot.handled
let slot_explicitly_forwarded slot = slot.explicitly_forwarded
let slot_recovery slot = slot.recovery

let compare_slot_order first second =
  let ordinal_order = Int.compare first.ordinal second.ordinal in
  if ordinal_order <> 0 then ordinal_order
  else String.compare first.id second.id

let compare_slot = Stdlib.compare
let equal_slot first second = compare_slot first second = 0

type t = {
  helper_fingerprint : string;
  effect_parameter : int;
  slots : slot list;
  output : symbolic_certificate;
}

type validation_error =
  | Empty_helper_fingerprint
  | Helper_fingerprint_has_surrounding_whitespace
  | Negative_effect_parameter of int
  | Duplicate_slot_id of slot_id
  | Duplicate_slot_ordinal of int
  | Too_many_slots of { limit : int; actual : int }
  | Expression_too_deep of { limit : int; actual : int }
  | Too_many_expression_nodes of { limit : int; actual : int }
  | Too_many_leaves of { limit : int; actual : int }
  | Invalid_expression of expression_error

type expression_stats = { nodes : int; leaves : int; depth : int }

let add_stats first second =
  {
    nodes = first.nodes + second.nodes;
    leaves = first.leaves + second.leaves;
    depth = Int.max first.depth second.depth;
  }

let evidence_leaf_count evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Exact_proof proof -> List.length (Proof.leaves proof)
  | Effect_certificate.Opaque_reasons _ -> 0

let rec expression_stats = function
  | Input_expression _ -> { nodes = 1; leaves = 0; depth = 1 }
  | Evidence_expression { evidence; _ } ->
      { nodes = 1; leaves = evidence_leaf_count evidence; depth = 1 }
  | Union_expression { terms; _ } ->
      let children =
        List.fold_left
          (fun total term -> add_stats total (expression_stats term))
          { nodes = 0; leaves = 0; depth = 0 }
          terms
      in
      { children with nodes = children.nodes + 1; depth = children.depth + 1 }
  | Subtract_expression { source; handled; explicitly_forwarded; recovery; _ }
    ->
      let children =
        add_stats (expression_stats source) (expression_stats recovery)
      in
      {
        nodes = children.nodes + 1;
        leaves =
          children.leaves
          + List.length handled
          + List.length explicitly_forwarded;
        depth = children.depth + 1;
      }

let validate_expression_limits expression =
  let stats = expression_stats expression in
  if stats.depth > max_expression_depth then
    Error
      (Expression_too_deep
         { limit = max_expression_depth; actual = stats.depth })
  else if stats.nodes > max_expression_nodes then
    Error
      (Too_many_expression_nodes
         { limit = max_expression_nodes; actual = stats.nodes })
  else if stats.leaves > max_leaves then
    Error (Too_many_leaves { limit = max_leaves; actual = stats.leaves })
  else Ok stats

let validate_contract_limits slots output =
  let expressions =
    output.errors
    :: output.requirements
    :: List.concat_map (fun slot -> [ slot.input; slot.recovery ]) slots
  in
  let slot_leaf_count =
    List.fold_left
      (fun total slot ->
        total
        + List.length slot.claimed
        + List.length slot.handled
        + List.length slot.explicitly_forwarded)
      0 slots
  in
  let rec loop total = function
    | [] ->
        if total.nodes > max_expression_nodes then
          Error
            (Too_many_expression_nodes
               { limit = max_expression_nodes; actual = total.nodes })
        else if total.leaves + slot_leaf_count > max_leaves then
          Error
            (Too_many_leaves
               { limit = max_leaves; actual = total.leaves + slot_leaf_count })
        else Ok ()
    | expression :: rest -> (
        match validate_expression_limits expression with
        | Error _ as error -> error
        | Ok stats -> loop (add_stats total stats) rest)
  in
  loop { nodes = 0; leaves = 0; depth = 0 } expressions

let find_duplicate projection compare values =
  let values =
    List.sort
      (fun first second -> compare (projection first) (projection second))
      values
  in
  let rec loop = function
    | first :: second :: _
      when compare (projection first) (projection second) = 0 ->
        Some (projection first)
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop values

let create ~helper_fingerprint ~effect_parameter ~slots ~output =
  let trimmed = String.trim helper_fingerprint in
  if String.equal trimmed "" then Error Empty_helper_fingerprint
  else if not (String.equal trimmed helper_fingerprint) then
    Error Helper_fingerprint_has_surrounding_whitespace
  else if effect_parameter < 0 then
    Error (Negative_effect_parameter effect_parameter)
  else if List.length slots > max_slots then
    Error (Too_many_slots { limit = max_slots; actual = List.length slots })
  else
    match find_duplicate (fun slot -> slot.id) String.compare slots with
    | Some id -> Error (Duplicate_slot_id id)
    | None -> (
        match find_duplicate (fun slot -> slot.ordinal) Int.compare slots with
        | Some ordinal -> Error (Duplicate_slot_ordinal ordinal)
        | None -> (
            let slots = List.sort compare_slot_order slots in
            match validate_contract_limits slots output with
            | Error _ as error -> error
            | Ok () ->
                Ok { helper_fingerprint; effect_parameter; slots; output }))

let helper_fingerprint contract = contract.helper_fingerprint
let effect_parameter contract = contract.effect_parameter
let slots contract = contract.slots
let output contract = contract.output
let compare = Stdlib.compare
let equal first second = compare first second = 0

type evaluation_error =
  | Opaque_expression of {
      kind : Kind.t;
      reasons : Effect_certificate.opacity list;
    }
  | Certificate_error of Effect_certificate.validation_error
  | Residual_error of Diagnostic.code
  | Evaluated_wrong_kind of { expected : Kind.t; actual : Kind.t }

let ( let* ) result function_ = Result.bind result function_

let evidence_for_kind input = function
  | Kind.Error -> Effect_certificate.errors input
  | Kind.Requirement -> Effect_certificate.requirements input

let require_exact kind evidence =
  match Effect_certificate.evidence_view evidence with
  | Effect_certificate.Exact_proof proof ->
      let actual = Proof.kind proof in
      if Kind.equal kind actual then Ok proof
      else Error (Evaluated_wrong_kind { expected = kind; actual })
  | Effect_certificate.Opaque_reasons reasons ->
      Error (Opaque_expression { kind; reasons })

let residual_arms ~handled ~explicitly_forwarded =
  let make action leaf =
    Residual.arm
      ~target:(Residual.Complete_leaf (Leaf.identity leaf))
      ~guard:Residual.Unguarded ~action
  in
  List.map (make Residual.Handle) handled
  @ List.map (make Residual.Forward) explicitly_forwarded

let calculate_residual ~source ~handled ~explicitly_forwarded ~recovery =
  Residual.calculate ~input:source
    ~arms:(residual_arms ~handled ~explicitly_forwarded)
    ~recovery:(Proof.leaves recovery)
  |> Result.map_error (fun error -> Residual_error error)

let rec evaluate_expression ~input expression =
  match expression with
  | Input_expression kind -> Ok (evidence_for_kind input kind)
  | Evidence_expression { evidence; _ } -> Ok evidence
  | Union_expression { kind; operation; inputs; terms } ->
      let rec evaluate_terms accumulated = function
        | [] -> Ok (List.rev accumulated)
        | term :: rest ->
            let* evidence = evaluate_expression ~input term in
            evaluate_terms (evidence :: accumulated) rest
      in
      let* evidence = evaluate_terms [] terms in
      Effect_certificate.union ~kind ~operation ~inputs evidence
      |> Result.map_error (fun error -> Certificate_error error)
  | Subtract_expression
      {
        kind;
        operation;
        inputs;
        source;
        handled;
        explicitly_forwarded;
        recovery;
      } ->
      let* source = evaluate_expression ~input source in
      let* source = require_exact kind source in
      let* recovery = evaluate_expression ~input recovery in
      let* recovery = require_exact kind recovery in
      let* residual =
        calculate_residual ~source ~handled ~explicitly_forwarded ~recovery
      in
      begin match
        Proof.create ~kind
          ~origin:(Proof.Composition { operation; inputs })
          ~leaves:(Residual.output residual)
      with
      | Ok proof -> Ok (Effect_certificate.exact proof)
      | Error _ ->
          Error
            (Certificate_error
               (Effect_certificate.Conflicting_exact_proofs kind))
      end

let evaluate ~input certificate =
  let* errors = evaluate_expression ~input certificate.errors in
  let* requirements = evaluate_expression ~input certificate.requirements in
  Effect_certificate.create ~errors ~requirements
  |> Result.map_error (fun error -> Certificate_error error)

type instantiated_slot = { slot : slot; residual : Residual.t }

let instantiate_slot ~input slot =
  let* source = evaluate_expression ~input slot.input in
  let* source = require_exact slot.kind source in
  let* () =
    match
      List.find_opt
        (fun leaf ->
          match Proof.find_leaf source (Leaf.identity leaf) with
          | Some source_leaf -> not (Leaf.equal source_leaf leaf)
          | None -> true)
        slot.claimed
    with
    | None -> Ok ()
    | Some leaf ->
        Error
          (Residual_error
             (Diagnostic.Leaf_outside_universe (Leaf.identity leaf)))
  in
  let* recovery = evaluate_expression ~input slot.recovery in
  let* recovery = require_exact slot.kind recovery in
  let* residual =
    calculate_residual ~source ~handled:slot.handled
      ~explicitly_forwarded:slot.explicitly_forwarded ~recovery
  in
  Ok { slot; residual }

let instantiate_slots ~input contract =
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | slot :: rest ->
        let* instantiated = instantiate_slot ~input slot in
        loop (instantiated :: accumulated) rest
  in
  loop [] contract.slots

let instantiated_slot instantiated = instantiated.slot
let instantiated_residual instantiated = instantiated.residual

type serialization_error =
  | Encoded_contract_too_large of { limit : int; actual : int }

type decode_error =
  | Decode_contract_too_large of { limit : int; actual : int }
  | Malformed_json of string
  | Malformed_contract of { path : string list; message : string }
  | Schema_version_mismatch of { expected : int; actual : int }
  | Invalid_contract of validation_error

let kind_to_json kind = `String (Kind.to_string kind)

let kind_of_json path = function
  | `String "error" -> Ok Kind.Error
  | `String "requirement" -> Ok Kind.Requirement
  | _ -> Error (Malformed_contract { path; message = "expected channel kind" })

let operation_to_string = function
  | Proof.Return -> "return"
  | Proof.Fail -> "fail"
  | Proof.Summon -> "summon"
  | Proof.Chain -> "chain"
  | Proof.Map -> "map"
  | Proof.Catch -> "catch"
  | Proof.Provide -> "provide"

let operation_of_string path = function
  | "return" -> Ok Proof.Return
  | "fail" -> Ok Proof.Fail
  | "summon" -> Ok Proof.Summon
  | "chain" -> Ok Proof.Chain
  | "map" -> Ok Proof.Map
  | "catch" -> Ok Proof.Catch
  | "provide" -> Ok Proof.Provide
  | _ -> Error (Malformed_contract { path; message = "unknown operation" })

let marker_ids_to_json ids =
  `List (List.map (fun id -> `String (Marker.id_to_string id)) ids)

let protocol_decode_error = function
  | Protocol.Version_mismatch { expected; actual } ->
      Malformed_contract
        {
          path = [];
          message =
            Printf.sprintf "nested protocol version mismatch: %d <> %d" expected
              actual;
        }
  | Protocol.Malformed { path; message } -> Malformed_contract { path; message }

let rec expression_to_json = function
  | Input_expression kind ->
      `Assoc [ ("node", `String "input"); ("kind", kind_to_json kind) ]
  | Evidence_expression { kind; evidence } ->
      `Assoc
        [
          ("node", `String "evidence");
          ("kind", kind_to_json kind);
          ("evidence", Protocol.evidence_to_json evidence);
        ]
  | Union_expression { kind; operation; inputs; terms } ->
      `Assoc
        [
          ("node", `String "union");
          ("kind", kind_to_json kind);
          ("operation", `String (operation_to_string operation));
          ("inputs", marker_ids_to_json inputs);
          ("terms", `List (List.map expression_to_json terms));
        ]
  | Subtract_expression
      {
        kind;
        operation;
        inputs;
        source;
        handled;
        explicitly_forwarded;
        recovery;
      } ->
      `Assoc
        [
          ("node", `String "subtract");
          ("kind", kind_to_json kind);
          ("operation", `String (operation_to_string operation));
          ("inputs", marker_ids_to_json inputs);
          ("source", expression_to_json source);
          ("handled", `List (List.map Protocol.leaf_to_json handled));
          ( "explicitly_forwarded",
            `List (List.map Protocol.leaf_to_json explicitly_forwarded) );
          ("recovery", expression_to_json recovery);
        ]

let slot_to_json slot =
  `Assoc
    [
      ("id", `String slot.id);
      ("ordinal", `Int slot.ordinal);
      ("kind", kind_to_json slot.kind);
      ("input", expression_to_json slot.input);
      ("claimed", `List (List.map Protocol.leaf_to_json slot.claimed));
      ("handled", `List (List.map Protocol.leaf_to_json slot.handled));
      ( "explicitly_forwarded",
        `List (List.map Protocol.leaf_to_json slot.explicitly_forwarded) );
      ("recovery", expression_to_json slot.recovery);
    ]

let certificate_to_json certificate =
  `Assoc
    [
      ("errors", expression_to_json certificate.errors);
      ("requirements", expression_to_json certificate.requirements);
    ]

let contract_to_json contract =
  `Assoc
    [
      ("protocol", `String "hamlet-subtractor-generic-contract");
      ("schema_version", `Int schema_version);
      ("helper_fingerprint", `String contract.helper_fingerprint);
      ("effect_parameter", `Int contract.effect_parameter);
      ("slots", `List (List.map slot_to_json contract.slots));
      ("output", certificate_to_json contract.output);
    ]

let encode contract =
  let encoded = contract |> contract_to_json |> Yojson.Safe.to_string in
  let actual = String.length encoded in
  if actual > max_encoded_bytes then
    Error (Encoded_contract_too_large { limit = max_encoded_bytes; actual })
  else Ok encoded

let digest contract =
  Result.map
    (fun encoded -> Digest.BLAKE256.to_hex (Digest.BLAKE256.string encoded))
    (encode contract)

let malformed path message = Error (Malformed_contract { path; message })

let object_fields path = function
  | `Assoc fields -> Ok fields
  | _ -> malformed path "expected object"

let field path name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> malformed (path @ [ name ]) "missing field"

let string path = function
  | `String value -> Ok value
  | _ -> malformed path "expected string"

let int path = function
  | `Int value -> Ok value
  | _ -> malformed path "expected integer"

let list path = function
  | `List values -> Ok values
  | _ -> malformed path "expected list"

let decode_list decoder path values =
  let rec loop index accumulated = function
    | [] -> Ok (List.rev accumulated)
    | value :: rest ->
        let* decoded = decoder (path @ [ string_of_int index ]) value in
        loop (index + 1) (decoded :: accumulated) rest
  in
  loop 0 [] values

let marker_ids_of_json path json =
  let* values = list path json in
  decode_list
    (fun item_path json ->
      let* value = string item_path json in
      match Marker.id_of_string value with
      | Ok id -> Ok id
      | Error _ -> malformed item_path "invalid marker identity")
    path values

let leaves_of_json path json =
  let* values = list path json in
  decode_list
    (fun item_path value ->
      Protocol.leaf_of_json item_path value
      |> Result.map_error protocol_decode_error)
    path values

let rec expression_of_json depth path json =
  if depth > max_expression_depth then
    malformed path "expression nesting exceeds the contract limit"
  else
    let* fields = object_fields path json in
    let* node_json = field path "node" fields in
    let* node = string (path @ [ "node" ]) node_json in
    let* kind_json = field path "kind" fields in
    let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
    match node with
    | "input" -> Ok (input kind)
    | "evidence" ->
        let* evidence_json = field path "evidence" fields in
        let* evidence =
          Protocol.evidence_of_json (path @ [ "evidence" ]) evidence_json
          |> Result.map_error protocol_decode_error
        in
        begin match Effect_certificate.evidence_view evidence with
        | Effect_certificate.Exact_proof proof
          when not (Kind.equal kind (Proof.kind proof)) ->
            malformed (path @ [ "evidence" ]) "evidence uses the wrong channel"
        | _ -> Ok (Evidence_expression { kind; evidence })
        end
    | "union" ->
        let* operation_json = field path "operation" fields in
        let* operation_name = string (path @ [ "operation" ]) operation_json in
        let* operation =
          operation_of_string (path @ [ "operation" ]) operation_name
        in
        let* inputs_json = field path "inputs" fields in
        let* inputs = marker_ids_of_json (path @ [ "inputs" ]) inputs_json in
        let* terms_json = field path "terms" fields in
        let* terms = list (path @ [ "terms" ]) terms_json in
        let* terms =
          decode_list
            (expression_of_json (depth + 1))
            (path @ [ "terms" ]) terms
        in
        union ~kind ~operation ~inputs terms
        |> Result.map_error (fun error ->
            Invalid_contract (Invalid_expression error))
    | "subtract" ->
        let* operation_json = field path "operation" fields in
        let* operation_name = string (path @ [ "operation" ]) operation_json in
        let* operation =
          operation_of_string (path @ [ "operation" ]) operation_name
        in
        let* inputs_json = field path "inputs" fields in
        let* inputs = marker_ids_of_json (path @ [ "inputs" ]) inputs_json in
        let* source_json = field path "source" fields in
        let* source =
          expression_of_json (depth + 1) (path @ [ "source" ]) source_json
        in
        let* handled_json = field path "handled" fields in
        let* handled = leaves_of_json (path @ [ "handled" ]) handled_json in
        let* forwarded_json = field path "explicitly_forwarded" fields in
        let* explicitly_forwarded =
          leaves_of_json (path @ [ "explicitly_forwarded" ]) forwarded_json
        in
        let* recovery_json = field path "recovery" fields in
        let* recovery =
          expression_of_json (depth + 1) (path @ [ "recovery" ]) recovery_json
        in
        subtract ~operation ~inputs ~source ~handled ~explicitly_forwarded
          ~recovery
        |> Result.map_error (fun error ->
            Invalid_contract (Invalid_expression error))
    | _ -> malformed (path @ [ "node" ]) "unknown expression node"

let slot_of_json path json =
  let* fields = object_fields path json in
  let* id_json = field path "id" fields in
  let* id_value = string (path @ [ "id" ]) id_json in
  let* id =
    match slot_id id_value with
    | Ok id -> Ok id
    | Error Empty_slot_id ->
        malformed (path @ [ "id" ]) "slot identity is empty"
    | Error Slot_id_has_surrounding_whitespace ->
        malformed (path @ [ "id" ]) "slot identity has surrounding whitespace"
    | Error (Negative_slot_ordinal _ | Slot_expression_error _) -> assert false
  in
  let* ordinal_json = field path "ordinal" fields in
  let* ordinal = int (path @ [ "ordinal" ]) ordinal_json in
  let* kind_json = field path "kind" fields in
  let* kind = kind_of_json (path @ [ "kind" ]) kind_json in
  let* input_json = field path "input" fields in
  let* input = expression_of_json 1 (path @ [ "input" ]) input_json in
  let* claimed_json = field path "claimed" fields in
  let* claimed = leaves_of_json (path @ [ "claimed" ]) claimed_json in
  let* handled_json = field path "handled" fields in
  let* handled = leaves_of_json (path @ [ "handled" ]) handled_json in
  let* forwarded_json = field path "explicitly_forwarded" fields in
  let* explicitly_forwarded =
    leaves_of_json (path @ [ "explicitly_forwarded" ]) forwarded_json
  in
  let* recovery_json = field path "recovery" fields in
  let* recovery = expression_of_json 1 (path @ [ "recovery" ]) recovery_json in
  slot ~id ~ordinal ~kind ~input ~claimed ~handled ~explicitly_forwarded
    ~recovery
  |> Result.map_error (fun _ ->
      Malformed_contract { path; message = "invalid forwarding slot" })

let certificate_of_json path json =
  let* fields = object_fields path json in
  let* errors_json = field path "errors" fields in
  let* errors = expression_of_json 1 (path @ [ "errors" ]) errors_json in
  let* requirements_json = field path "requirements" fields in
  let* requirements =
    expression_of_json 1 (path @ [ "requirements" ]) requirements_json
  in
  certificate ~errors ~requirements
  |> Result.map_error (fun error -> Invalid_contract (Invalid_expression error))

let decode_value json =
  let path = [] in
  let* fields = object_fields path json in
  let* protocol_json = field path "protocol" fields in
  let* protocol = string [ "protocol" ] protocol_json in
  let* () =
    if String.equal protocol "hamlet-subtractor-generic-contract" then Ok ()
    else malformed [ "protocol" ] "unexpected protocol name"
  in
  let* version_json = field path "schema_version" fields in
  let* actual = int [ "schema_version" ] version_json in
  let* () =
    if actual = schema_version then Ok ()
    else Error (Schema_version_mismatch { expected = schema_version; actual })
  in
  let* fingerprint_json = field path "helper_fingerprint" fields in
  let* helper_fingerprint = string [ "helper_fingerprint" ] fingerprint_json in
  let* parameter_json = field path "effect_parameter" fields in
  let* effect_parameter = int [ "effect_parameter" ] parameter_json in
  let* slots_json = field path "slots" fields in
  let* slot_values = list [ "slots" ] slots_json in
  let* slots = decode_list slot_of_json [ "slots" ] slot_values in
  let* output_json = field path "output" fields in
  let* output = certificate_of_json [ "output" ] output_json in
  create ~helper_fingerprint ~effect_parameter ~slots ~output
  |> Result.map_error (fun error -> Invalid_contract error)

let decode encoded =
  let actual = String.length encoded in
  if actual > max_encoded_bytes then
    Error (Decode_contract_too_large { limit = max_encoded_bytes; actual })
  else
    try decode_value (Yojson.Safe.from_string encoded) with
    | Yojson.Json_error message -> Error (Malformed_json message)
    | Stack_overflow -> Error (Malformed_json "JSON nesting is too deep")
