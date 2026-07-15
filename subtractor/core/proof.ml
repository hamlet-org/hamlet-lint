type composition = Return | Fail | Summon | Chain | Map | Catch | Provide

type origin =
  | Closed_row
  | Generalized_value of Identity.t
  | External_value of Identity.t
  | Composition of { operation : composition; inputs : Marker.id list }

type t = { kind : Kind.t; origin : origin; leaves : Leaf.t list }

type validation_error =
  | Wrong_leaf_kind of { leaf : Identity.t; expected : Kind.t; actual : Kind.t }
  | Duplicate_leaf_identity of Identity.t
  | Overlapping_atom of {
      atom : Atom.t;
      first_leaf : Identity.t;
      second_leaf : Identity.t;
    }

let normalize_leaves leaves =
  List.sort
    (fun a b -> Identity.compare (Leaf.identity a) (Leaf.identity b))
    leaves

let validate_kinds kind leaves =
  match
    List.find_opt (fun leaf -> not (Kind.equal kind (Leaf.kind leaf))) leaves
  with
  | None -> Ok ()
  | Some leaf ->
      Error
        (Wrong_leaf_kind
           {
             leaf = Leaf.identity leaf;
             expected = kind;
             actual = Leaf.kind leaf;
           })

let validate_unique_identities leaves =
  let rec loop = function
    | first :: second :: _
      when Identity.equal (Leaf.identity first) (Leaf.identity second) ->
        Error (Duplicate_leaf_identity (Leaf.identity first))
    | _ :: rest -> loop rest
    | [] -> Ok ()
  in
  loop leaves

module Structural_atom_map = Map.Make (struct
  type t = Atom.t

  let compare = Atom.compare_structural
end)

let validate_partition leaves =
  let add_leaf seen leaf =
    let rec add_members seen = function
      | [] -> Ok seen
      | atom :: rest -> (
          match Structural_atom_map.find_opt atom seen with
          | Some first_leaf ->
              Error
                (Overlapping_atom
                   { atom; first_leaf; second_leaf = Leaf.identity leaf })
          | None ->
              add_members
                (Structural_atom_map.add atom (Leaf.identity leaf) seen)
                rest)
    in
    add_members seen (Leaf.members leaf)
  in
  let rec loop seen = function
    | [] -> Ok ()
    | leaf :: rest -> (
        match add_leaf seen leaf with
        | Error _ as error -> error
        | Ok seen -> loop seen rest)
  in
  loop Structural_atom_map.empty leaves

let normalize_origin = function
  | Composition { operation; inputs } ->
      Composition
        { operation; inputs = List.sort_uniq Marker.compare_id inputs }
  | origin -> origin

let create ~kind ~origin ~leaves =
  match validate_kinds kind leaves with
  | Error _ as error -> error
  | Ok () ->
      let leaves = normalize_leaves leaves in
      begin match validate_unique_identities leaves with
      | Error _ as error -> error
      | Ok () -> (
          match validate_partition leaves with
          | Error _ as error -> error
          | Ok () -> Ok { kind; origin = normalize_origin origin; leaves })
      end

let kind t = t.kind
let origin t = t.origin
let leaves t = t.leaves
let atoms t = List.concat_map Leaf.members t.leaves

let find_leaf t identity =
  List.find_opt
    (fun leaf -> Identity.equal identity (Leaf.identity leaf))
    t.leaves

let compare = Stdlib.compare
let equal a b = compare a b = 0
