type unmaterializable_reason =
  | Abstract_declaration
  | Hidden_alias
  | Missing_cases_catalogue
  | No_named_pattern
  | Grouped_requirement

type materialization =
  | Direct
  | Structural_variant
  | Error_cases of {
      catalogue : Identity.t;
      union : Identity.t;
      field : string;
    }
  | Requirement_tag
  | Unavailable of unmaterializable_reason

type t = {
  identity : Identity.t;
  kind : Kind.t;
  members : Atom.t list;
  materialization : materialization;
}

type validation_error =
  | Empty_error_leaf
  | Wrong_member_kind of { expected : Kind.t; actual : Kind.t }
  | Duplicate_member of Atom.t
  | Invalid_materialization of {
      kind : Kind.t;
      materialization : materialization;
    }
  | Empty_cases_field

let normalize_members members =
  let sorted = List.sort Atom.compare members in
  let rec loop acc = function
    | a :: b :: _ when Atom.equal a b -> Error (Duplicate_member a)
    | member :: rest -> loop (member :: acc) rest
    | [] -> Ok (List.rev acc)
  in
  loop [] sorted

let validate_member_kind expected members =
  match
    List.find_opt
      (fun member -> not (Kind.equal expected (Atom.kind member)))
      members
  with
  | None -> Ok ()
  | Some member ->
      Error (Wrong_member_kind { expected; actual = Atom.kind member })

let validate_materialization kind members = function
  | Structural_variant as materialization when List.length members <> 1 ->
      Error (Invalid_materialization { kind; materialization })
  | Error_cases { field; _ } when String.trim field = "" ->
      Error Empty_cases_field
  | Error_cases _ as materialization when Kind.equal kind Kind.Requirement ->
      Error (Invalid_materialization { kind; materialization })
  | Requirement_tag as materialization when Kind.equal kind Kind.Error ->
      Error (Invalid_materialization { kind; materialization })
  | _ -> Ok ()

let make ~identity ~kind ~members ~materialization =
  match validate_member_kind kind members with
  | Error _ as error -> error
  | Ok () -> (
      match validate_materialization kind members materialization with
      | Error _ as error -> error
      | Ok () -> (
          match normalize_members members with
          | Error _ as error -> error
          | Ok members -> Ok { identity; kind; members; materialization }))

let error ~identity ~members ~materialization =
  match members with
  | [] -> Error Empty_error_leaf
  | _ -> make ~identity ~kind:Kind.Error ~members ~materialization

let requirement ~identity ~member ~materialization =
  make ~identity ~kind:Kind.Requirement ~members:[ member ] ~materialization

let identity t = t.identity
let kind t = t.kind
let members t = t.members
let materialization t = t.materialization
let is_grouped t = match t.members with _ :: _ :: _ -> true | _ -> false

let is_materializable t =
  match t.materialization with Unavailable _ -> false | _ -> true

let compare = Stdlib.compare
let equal a b = compare a b = 0
