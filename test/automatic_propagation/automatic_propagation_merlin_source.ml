let require_clean fields =
  match
    (List.assoc_opt "class" fields, List.assoc_opt "notifications" fields)
  with
  | Some (`String "return"), Some (`List []) -> ()
  | _ -> failwith "Merlin response is not a clean return"

let () =
  if Array.length Sys.argv <> 2 then
    invalid_arg "usage: automatic_propagation_merlin_source MERLIN_JSON";
  match Yojson.Safe.from_file Sys.argv.(1) with
  | `Assoc fields -> (
      require_clean fields;
      match List.assoc_opt "value" fields with
      | Some (`String source) -> print_string source
      | _ -> failwith "Merlin response has no source value")
  | _ -> failwith "Merlin response is not an object"
