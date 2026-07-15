open Hamlet_subtractor_core

type resolved = { residual : Residual.t; certificate : Effect_certificate.t }

type 'context typed_backend = {
  dependencies :
    'context -> Marker.t -> (Marker.id list, Diagnostic.code) result;
  resolve :
    'context ->
    marker:Marker.t ->
    dependencies:(Marker.t * resolved) list ->
    (resolved, Diagnostic.code) result;
}

type marker_outcome = Marker.t * Protocol.outcome

type state_outcome = Resolved of resolved | Refused of Diagnostic.t

type t = {
  outcomes : marker_outcome list;
  catalogues : Hamlet_subtractor_catalogue.t list;
  resolved_values : (Marker.t * resolved) list;
}

type error = Duplicate_marker of Marker.id

type pending = { marker : Marker.t; dependencies : Marker.id list }

let marker_order left right =
  Marker.compare_id (Marker.id left) (Marker.id right)

let pending_order left right = marker_order left.marker right.marker

let find_duplicate markers =
  let rec loop = function
    | first :: (second :: _ as rest) ->
        if Marker.compare_id (Marker.id first) (Marker.id second) = 0 then
          Some (Marker.id first)
        else loop rest
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (List.sort marker_order markers)

let find_marker markers id =
  List.find_opt
    (fun marker -> Marker.compare_id id (Marker.id marker) = 0)
    markers

let find_state outcomes id =
  List.find_opt
    (fun (marker, _) -> Marker.compare_id id (Marker.id marker) = 0)
    outcomes

let diagnostic marker code = Refused (Diagnostic.make ~marker ~code)

let same_leaf_set left right =
  let sort = List.sort_uniq Leaf.compare in
  let left = sort left and right = sort right in
  List.length left = List.length right && List.for_all2 Leaf.equal left right

let target_certificate resolved =
  match Residual.kind resolved.residual with
  | Kind.Error -> Effect_certificate.errors resolved.certificate
  | Kind.Requirement -> Effect_certificate.requirements resolved.certificate

let validate_resolved marker resolved =
  let marker_kind = Marker.kind marker in
  let residual_kind = Residual.kind resolved.residual in
  if not (Kind.equal marker_kind residual_kind) then
    Error
      (Diagnostic.Wrong_channel
         { expected = marker_kind; actual = residual_kind })
  else
    match Effect_certificate.evidence_view (target_certificate resolved) with
    | Effect_certificate.Opaque_reasons _ -> Ok resolved
    | Effect_certificate.Exact_proof proof ->
        if
          same_leaf_set (Proof.leaves proof) (Residual.output resolved.residual)
        then Ok resolved
        else Error Diagnostic.Opaque_origin

let prepare_pending ~(backend : _ typed_backend) ~context markers =
  List.fold_left
    (fun (pending, outcomes) marker ->
      match backend.dependencies context marker with
      | Error code -> (pending, (marker, diagnostic marker code) :: outcomes)
      | Ok dependencies ->
          let dependencies = List.sort_uniq Marker.compare_id dependencies in
          let unknown =
            List.find_opt
              (fun id -> Option.is_none (find_marker markers id))
              dependencies
          in
          begin match unknown with
          | Some _ ->
              ( pending,
                (marker, diagnostic marker Diagnostic.Higher_order_flow)
                :: outcomes )
          | None -> ({ marker; dependencies } :: pending, outcomes)
          end)
    ([], []) markers
  |> fun (pending, outcomes) ->
  (List.sort pending_order pending, List.rev outcomes)

let dependency_results outcomes dependencies =
  List.filter_map (find_state outcomes) dependencies

let is_ready outcomes (pending : pending) =
  List.for_all
    (fun id -> Option.is_some (find_state outcomes id))
    pending.dependencies

let resolve_ready
    ~(backend : _ typed_backend)
    ~context
    outcomes
    (pending : pending) =
  let dependencies = dependency_results outcomes pending.dependencies in
  match
    List.find_opt (function _, Refused _ -> true | _ -> false) dependencies
  with
  | Some _ ->
      (pending.marker, diagnostic pending.marker Diagnostic.Opaque_origin)
  | None ->
      let dependencies =
        List.filter_map
          (function
            | marker, Resolved resolved -> Some (marker, resolved)
            | _, Refused _ -> None)
          dependencies
      in
      let outcome =
        match backend.resolve context ~marker:pending.marker ~dependencies with
        | Ok resolved -> (
            match validate_resolved pending.marker resolved with
            | Ok resolved -> Resolved resolved
            | Error code -> diagnostic pending.marker code)
        | Error code -> diagnostic pending.marker code
      in
      (pending.marker, outcome)

let pending_by_id (pending : pending list) id =
  List.find_opt
    (fun node -> Marker.compare_id id (Marker.id node.marker) = 0)
    pending

let reachable pending ~from ~target =
  let rec visit seen id =
    if Marker.compare_id id target = 0 then true
    else if List.exists (fun seen_id -> Marker.compare_id id seen_id = 0) seen
    then false
    else
      match pending_by_id pending id with
      | None -> false
      | Some (node : pending) ->
          List.exists (visit (id :: seen)) node.dependencies
  in
  visit [] from

let has_self_edge (node : pending) =
  List.exists
    (fun id -> Marker.compare_id id (Marker.id node.marker) = 0)
    node.dependencies

let cycle_components pending =
  let rec loop assigned components = function
    | [] -> List.rev components
    | node :: rest
      when List.exists
             (fun id -> Marker.compare_id id (Marker.id node.marker) = 0)
             assigned ->
        loop assigned components rest
    | node :: rest ->
        let id = Marker.id node.marker in
        let component =
          List.filter
            (fun candidate ->
              let candidate_id = Marker.id candidate.marker in
              reachable pending ~from:id ~target:candidate_id
              && reachable pending ~from:candidate_id ~target:id)
            pending
        in
        let cyclic = List.length component > 1 || has_self_edge node in
        if not cyclic then loop assigned components rest
        else
          let ids =
            List.map (fun member -> Marker.id member.marker) component
          in
          loop (ids @ assigned) (component :: components) rest
  in
  loop [] [] pending

let refuse_cycles outcomes pending =
  let components = cycle_components pending in
  let refused_ids =
    List.concat_map
      (fun component -> List.map (fun node -> Marker.id node.marker) component)
      components
  in
  let cycle_outcomes =
    List.concat_map
      (fun component ->
        let ids =
          component
          |> List.map (fun node -> Marker.id node.marker)
          |> List.sort Marker.compare_id
        in
        List.map
          (fun node ->
            ( node.marker,
              diagnostic node.marker (Diagnostic.Recursive_dependency ids) ))
          component)
      components
  in
  let pending =
    List.filter
      (fun node ->
        not
          (List.exists
             (fun id -> Marker.compare_id id (Marker.id node.marker) = 0)
             refused_ids))
      pending
  in
  (cycle_outcomes @ outcomes, pending)

let elaborate ~(backend : _ typed_backend) ~context ~catalogues ~markers =
  match find_duplicate markers with
  | Some id -> Error (Duplicate_marker id)
  | None ->
      let markers = List.sort marker_order markers in
      let pending, outcomes = prepare_pending ~backend ~context markers in
      let rec fixed_point outcomes pending =
        match pending with
        | [] -> outcomes
        | _ ->
            let ready, blocked = List.partition (is_ready outcomes) pending in
            if ready <> [] then
              let produced =
                List.map (resolve_ready ~backend ~context outcomes) ready
              in
              fixed_point (produced @ outcomes) blocked
            else
              let outcomes, pending = refuse_cycles outcomes pending in
              if pending = blocked then
                (* a finite blocked graph must contain a cycle; this branch is
                   defensive and turns an impossible backend graph into a
                   stable higher-order refusal. *)
                let refused =
                  List.map
                    (fun node ->
                      ( node.marker,
                        diagnostic node.marker Diagnostic.Higher_order_flow ))
                    pending
                in
                refused @ outcomes
              else fixed_point outcomes pending
      in
      let outcomes =
        fixed_point outcomes pending
        |> List.sort (fun (left, _) (right, _) -> marker_order left right)
      in
      let protocol_outcomes =
        List.map
          (function
            | marker, Resolved { residual; _ } ->
                (marker, Protocol.Resolved residual)
            | marker, Refused diagnostic -> (marker, Protocol.Refused diagnostic))
          outcomes
      in
      let resolved_values =
        List.filter_map
          (function
            | marker, Resolved resolved -> Some (marker, resolved)
            | _, Refused _ -> None)
          outcomes
      in
      Ok { outcomes = protocol_outcomes; catalogues; resolved_values }

let outcomes t = t.outcomes
let catalogues t = t.catalogues
let resolved_values t = t.resolved_values

let of_response response =
  let outcomes =
    Protocol.results response
    |> List.map (fun result ->
        (Protocol.marker result, Protocol.outcome result))
  in
  let resolved_values =
    Protocol.results response
    |> List.filter_map (fun result ->
        match (Protocol.outcome result, Protocol.certificate result) with
        | Protocol.Resolved residual, Some certificate ->
            Some (Protocol.marker result, { residual; certificate })
        | Protocol.Refused _, None -> None
        | Protocol.Resolved _, None | Protocol.Refused _, Some _ -> assert false)
  in
  let catalogues =
    Protocol.catalogues response
    |> List.map Hamlet_subtractor_catalogue.of_protocol
  in
  { outcomes; catalogues; resolved_values }
