type opacity = Unproven_origin | Opaque_recovery | Opaque_handler

type evidence = Exact of Proof.t | Opaque of opacity list
type evidence_view = Exact_proof of Proof.t | Opaque_reasons of opacity list
type t = { errors : evidence; requirements : evidence }

type validation_error =
  | Wrong_channel of { expected : Kind.t; actual : Kind.t }
  | Input_proof_mismatch of Kind.t
  | Contributing_proof_mismatch of Kind.t
  | Conflicting_exact_proofs of Kind.t

let normalize_opacity reasons = List.sort_uniq Stdlib.compare reasons

let exact proof = Exact proof
let opaque reason = Opaque [ reason ]

let opaque_many reasons =
  match normalize_opacity reasons with
  | [] -> None
  | reasons -> Some (Opaque reasons)

let evidence_view = function
  | Exact proof -> Exact_proof proof
  | Opaque reasons -> Opaque_reasons reasons

let validate_evidence expected = function
  | Opaque _ -> Ok ()
  | Exact proof ->
      let actual = Proof.kind proof in
      if Kind.equal expected actual then Ok ()
      else Error (Wrong_channel { expected; actual })

let create ~errors ~requirements =
  match validate_evidence Kind.Error errors with
  | Error _ as error -> error
  | Ok () -> (
      match validate_evidence Kind.Requirement requirements with
      | Error _ as error -> error
      | Ok () ->
          let normalize = function
            | Exact _ as evidence -> evidence
            | Opaque reasons -> Opaque (normalize_opacity reasons)
          in
          Ok
            { errors = normalize errors; requirements = normalize requirements }
      )

let errors certificate = certificate.errors
let requirements certificate = certificate.requirements

let union_exact ~kind ~operation ~inputs proofs =
  let leaves =
    proofs |> List.concat_map Proof.leaves |> List.sort_uniq Leaf.compare
  in
  match
    Proof.create ~kind ~origin:(Proof.Composition { operation; inputs }) ~leaves
  with
  | Ok proof -> Ok (Exact proof)
  | Error _ -> Error (Conflicting_exact_proofs kind)

let union_evidence ~kind ~operation ~inputs evidence =
  let opaque_reasons =
    evidence
    |> List.concat_map (function Opaque reasons -> reasons | Exact _ -> [])
  in
  if opaque_reasons <> [] then Ok (Opaque (normalize_opacity opaque_reasons))
  else
    let proofs =
      List.filter_map
        (function Exact proof -> Some proof | Opaque _ -> None)
        evidence
    in
    union_exact ~kind ~operation ~inputs proofs

let union = union_evidence

let chain ~inputs certificates =
  let errors =
    certificates
    |> List.map errors
    |> union_evidence ~kind:Kind.Error ~operation:Proof.Chain ~inputs
  in
  let requirements =
    certificates
    |> List.map requirements
    |> union_evidence ~kind:Kind.Requirement ~operation:Proof.Chain ~inputs
  in
  match (errors, requirements) with
  | Ok errors, Ok requirements -> create ~errors ~requirements
  | (Error _ as error), _ | _, (Error _ as error) -> error

let recover ~inputs ~source ~recoveries =
  let errors =
    recoveries
    |> List.map errors
    |> union_evidence ~kind:Kind.Error ~operation:Proof.Catch ~inputs
  in
  let requirements =
    source.requirements :: List.map requirements recoveries
    |> union_evidence ~kind:Kind.Requirement ~operation:Proof.Catch ~inputs
  in
  match (errors, requirements) with
  | Ok errors, Ok requirements -> create ~errors ~requirements
  | (Error _ as error), _ | _, (Error _ as error) -> error

let with_errors ~source ~errors =
  create ~errors ~requirements:source.requirements

let with_requirements ~source ~requirements =
  create ~errors:source.errors ~requirements

let proof_from_result ~operation ~inputs result =
  Proof.create ~kind:(Residual.kind result)
    ~origin:(Proof.Composition { operation; inputs })
    ~leaves:(Residual.output result)
  |> function
  | Ok proof -> Ok (Exact proof)
  | Error _ -> Error (Conflicting_exact_proofs (Residual.kind result))

let exact_proofs evidence =
  List.filter_map
    (function Exact proof -> Some proof | Opaque _ -> None)
    evidence

let exact_leaf_union kind proofs =
  let leaves =
    proofs |> List.concat_map Proof.leaves |> List.sort_uniq Leaf.compare
  in
  match Proof.create ~kind ~origin:Proof.Closed_row ~leaves with
  | Ok proof -> Ok (Proof.leaves proof)
  | Error _ -> Error (Conflicting_exact_proofs kind)

let validate_input expected result evidence =
  match evidence with
  | Opaque _ -> Error (Input_proof_mismatch expected)
  | Exact proof ->
      if Proof.equal proof (Residual.input result) then Ok ()
      else Error (Input_proof_mismatch expected)

let validate_contributors kind result evidence =
  if List.exists (function Opaque _ -> true | Exact _ -> false) evidence then
    Ok false
  else
    match exact_leaf_union kind (exact_proofs evidence) with
    | Error _ as error -> error
    | Ok leaves ->
        if leaves = Residual.recovery result then Ok true
        else Error (Contributing_proof_mismatch kind)

let catch ~inputs ~source ~error_result ~recoveries =
  if not (Kind.equal (Residual.kind error_result) Kind.Error) then
    Error
      (Wrong_channel
         { expected = Kind.Error; actual = Residual.kind error_result })
  else
    match validate_input Kind.Error error_result source.errors with
    | Error _ as error -> error
    | Ok () ->
        let recovery_errors = List.map errors recoveries in
        begin match
          validate_contributors Kind.Error error_result recovery_errors
        with
        | Error _ as error -> error
        | Ok recovery_is_exact ->
            let errors =
              if recovery_is_exact then
                proof_from_result ~operation:Proof.Catch ~inputs error_result
              else
                Ok
                  (Opaque
                     (Opaque_recovery
                      :: (recovery_errors
                         |> List.concat_map (function
                           | Opaque reasons -> reasons
                           | Exact _ -> []))
                     |> normalize_opacity))
            in
            let requirements =
              source.requirements :: List.map requirements recoveries
              |> union_evidence ~kind:Kind.Requirement ~operation:Proof.Catch
                   ~inputs
            in
            begin match (errors, requirements) with
            | Ok errors, Ok requirements -> create ~errors ~requirements
            | (Error _ as error), _ | _, (Error _ as error) -> error
            end
        end

let provide ~inputs ~source ~requirement_result ~handlers =
  if not (Kind.equal (Residual.kind requirement_result) Kind.Requirement) then
    Error
      (Wrong_channel
         {
           expected = Kind.Requirement;
           actual = Residual.kind requirement_result;
         })
  else
    match
      validate_input Kind.Requirement requirement_result source.requirements
    with
    | Error _ as error -> error
    | Ok () ->
        let handler_requirements = List.map requirements handlers in
        begin match
          validate_contributors Kind.Requirement requirement_result
            handler_requirements
        with
        | Error _ as error -> error
        | Ok handlers_are_exact ->
            let requirements =
              if handlers_are_exact then
                proof_from_result ~operation:Proof.Provide ~inputs
                  requirement_result
              else
                Ok
                  (Opaque
                     (Opaque_handler
                      :: (handler_requirements
                         |> List.concat_map (function
                           | Opaque reasons -> reasons
                           | Exact _ -> []))
                     |> normalize_opacity))
            in
            let errors =
              source.errors :: List.map errors handlers
              |> union_evidence ~kind:Kind.Error ~operation:Proof.Provide
                   ~inputs
            in
            begin match (errors, requirements) with
            | Ok errors, Ok requirements -> create ~errors ~requirements
            | (Error _ as error), _ | _, (Error _ as error) -> error
            end
        end

let compare = Stdlib.compare
let equal first second = compare first second = 0
