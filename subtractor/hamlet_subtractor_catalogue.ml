open Hamlet_subtractor_core

type field = { name : string; leaf : Identity.t }

type t = { identity : Identity.t; union : Identity.t; fields : field list }

type validation_error =
  | Empty_catalogue
  | Empty_field_name of Identity.t
  | Duplicate_field_name of string
  | Duplicate_leaf of Identity.t

let validate_fields fields =
  let rec loop names leaves = function
    | [] -> Ok ()
    | { name; leaf } :: rest ->
        if String.trim name = "" then Error (Empty_field_name leaf)
        else if List.exists (String.equal name) names then
          Error (Duplicate_field_name name)
        else if List.exists (Identity.equal leaf) leaves then
          Error (Duplicate_leaf leaf)
        else loop (name :: names) (leaf :: leaves) rest
  in
  match fields with [] -> Error Empty_catalogue | _ -> loop [] [] fields

let create ~identity ~union ~fields =
  match validate_fields fields with
  | Error _ as error -> error
  | Ok () -> Ok { identity; union; fields }

let identity t = t.identity
let union t = t.union
let fields t = t.fields

let to_protocol t =
  Hamlet_subtractor_core.Protocol.catalogue ~identity:t.identity ~union:t.union
    ~fields:(List.map (fun field -> (field.name, field.leaf)) t.fields)
  |> Result.get_ok

let of_protocol catalogue =
  let identity = Hamlet_subtractor_core.Protocol.catalogue_identity catalogue in
  let union = Hamlet_subtractor_core.Protocol.catalogue_union catalogue in
  let fields =
    Hamlet_subtractor_core.Protocol.catalogue_fields catalogue
    |> List.map (fun (name, leaf) -> { name; leaf })
  in
  create ~identity ~union ~fields |> Result.get_ok

let compare = Stdlib.compare
let equal first second = compare first second = 0
