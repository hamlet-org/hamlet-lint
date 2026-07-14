type guard = Unguarded | Guarded
type action = Handle | Forward

type target = Complete_leaf of Identity.t | Structural_member of Atom.t

type arm = { target : target; guard : guard; action : action }

type t = {
  input : Proof.t;
  arms : arm list;
  handled : Leaf.t list;
  forwarded : Leaf.t list;
  recovery : Leaf.t list;
  residual : Leaf.t list;
  output : Leaf.t list;
}

let arm ~target ~guard ~action = { target; guard; action }
let target arm = arm.target
let guard arm = arm.guard
let action arm = arm.action

let compare_target first second =
  match (first, second) with
  | Complete_leaf first, Complete_leaf second -> Identity.compare first second
  | Complete_leaf _, Structural_member _ -> -1
  | Structural_member _, Complete_leaf _ -> 1
  | Structural_member first, Structural_member second ->
      Atom.compare first second

let compare_arm first second =
  let target_order = compare_target first.target second.target in
  if target_order <> 0 then target_order
  else
    let guard_order = Stdlib.compare first.guard second.guard in
    if guard_order <> 0 then guard_order
    else Stdlib.compare first.action second.action

let leaf_order first second =
  Identity.compare (Leaf.identity first) (Leaf.identity second)

let find_structural_leaf input atom =
  Proof.leaves input
  |> List.filter (fun leaf ->
      List.exists
        (fun member -> Atom.equal_structural atom member)
        (Leaf.members leaf))

let resolve_target input = function
  | Complete_leaf identity -> (
      match Proof.find_leaf input identity with
      | Some leaf -> Ok leaf
      | None -> Error (Diagnostic.Leaf_outside_universe identity))
  | Structural_member atom -> (
      match find_structural_leaf input atom with
      | [] -> Error (Diagnostic.Atoms_outside_universe [ atom ])
      | [ leaf ] when Leaf.is_grouped leaf ->
          Error
            (Diagnostic.Partially_handled_group { leaf; matched = [ atom ] })
      | [ leaf ] -> Ok leaf
      | _ -> Error (Diagnostic.Atoms_outside_universe [ atom ]))

let normalize_leaf_list kind leaves =
  let leaves = List.sort_uniq Leaf.compare leaves in
  match Proof.create ~kind ~origin:Proof.Closed_row ~leaves with
  | Ok proof -> Ok (Proof.leaves proof)
  | Error (Proof.Wrong_leaf_kind { actual; _ }) ->
      Error (Diagnostic.Wrong_channel { expected = kind; actual })
  | Error (Proof.Duplicate_leaf_identity identity)
  | Error (Proof.Overlapping_atom { second_leaf = identity; _ }) ->
      Error (Diagnostic.Conflicting_recovery_leaf identity)

let add_unique_leaf leaf leaves =
  if List.exists (fun current -> Leaf.equal leaf current) leaves then leaves
  else leaf :: leaves

let validate_arms input arms =
  let rec loop seen handled forwarded = function
    | [] -> Ok (handled, forwarded)
    | arm :: rest -> (
        match resolve_target input arm.target with
        | Error _ as error -> error
        | Ok leaf -> (
            match arm.guard with
            | Guarded -> loop seen handled forwarded rest
            | Unguarded -> (
                let identity = Leaf.identity leaf in
                if List.exists (Identity.equal identity) seen then
                  Error (Diagnostic.Duplicate_unguarded_arm identity)
                else
                  let seen = identity :: seen in
                  match arm.action with
                  | Handle ->
                      loop seen (add_unique_leaf leaf handled) forwarded rest
                  | Forward ->
                      loop seen handled (add_unique_leaf leaf forwarded) rest)))
  in
  loop [] [] [] arms

let ensure_materializable leaves =
  match
    List.find_opt (fun leaf -> not (Leaf.is_materializable leaf)) leaves
  with
  | None -> Ok ()
  | Some leaf -> Error (Diagnostic.Unmaterializable_leaf leaf)

let union_outputs kind lists = lists |> List.concat |> normalize_leaf_list kind

let calculate ~input ~arms ~recovery =
  let kind = Proof.kind input in
  match normalize_leaf_list kind recovery with
  | Error _ as error -> error
  | Ok recovery -> (
      match validate_arms input arms with
      | Error _ as error -> error
      | Ok (handled, forwarded) ->
          let covered = handled @ forwarded in
          let residual =
            Proof.leaves input
            |> List.filter (fun leaf ->
                not
                  (List.exists
                     (fun covered_leaf ->
                       Identity.equal (Leaf.identity leaf)
                         (Leaf.identity covered_leaf))
                     covered))
          in
          begin match ensure_materializable residual with
          | Error _ as error -> error
          | Ok () -> (
              match union_outputs kind [ residual; forwarded; recovery ] with
              | Error _ as error -> error
              | Ok output ->
                  Ok
                    {
                      input;
                      arms = List.sort compare_arm arms;
                      handled = List.sort leaf_order handled;
                      forwarded = List.sort leaf_order forwarded;
                      recovery;
                      residual;
                      output;
                    })
          end)

let kind t = Proof.kind t.input
let input t = t.input
let arms t = t.arms
let handled t = t.handled
let forwarded t = t.forwarded
let recovery t = t.recovery
let residual t = t.residual
let output t = t.output
let compare = Stdlib.compare
let equal a b = compare a b = 0
