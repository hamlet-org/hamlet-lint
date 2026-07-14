let find_type fields =
  match List.assoc_opt "type" fields with
  | Some (`String value) -> Some value
  | _ -> None

let require_clean fields =
  match
    (List.assoc_opt "class" fields, List.assoc_opt "notifications" fields)
  with
  | Some (`String "return"), Some (`List []) -> ()
  | _ -> failwith "Merlin response is not a clean return"

let () =
  if Array.length Sys.argv <> 2 then
    invalid_arg "usage: automatic_propagation_merlin_type MERLIN_JSON";
  match Yojson.Safe.from_file Sys.argv.(1) with
  | `Assoc fields -> (
      require_clean fields;
      match List.assoc_opt "value" fields with
      | Some (`List (`Assoc enclosing :: _)) -> (
          match find_type enclosing with
          | Some value -> print_endline value
          | None -> failwith "Merlin enclosing value has no type")
      | _ -> failwith "Merlin response has no enclosing values")
  | _ -> failwith "Merlin response is not an object"
