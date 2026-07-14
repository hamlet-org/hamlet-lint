type t = {
  module_path : string list;
  declaration_name : string;
  interface_digest : string;
}

type validation_error =
  | Empty_module_path
  | Empty_module_segment of int
  | Dotted_module_segment of { index : int; segment : string }
  | Empty_declaration_name
  | Empty_interface_digest

let validate_module_path = function
  | [] -> Error Empty_module_path
  | segments ->
      let rec loop index = function
        | [] -> Ok ()
        | segment :: rest ->
            if String.trim segment = "" then Error (Empty_module_segment index)
            else if String.contains segment '.' then
              Error (Dotted_module_segment { index; segment })
            else loop (index + 1) rest
      in
      loop 0 segments

let make ~module_path ~declaration_name ~interface_digest =
  match validate_module_path module_path with
  | Error _ as error -> error
  | Ok () ->
      if String.trim declaration_name = "" then Error Empty_declaration_name
      else if String.trim interface_digest = "" then
        Error Empty_interface_digest
      else Ok { module_path; declaration_name; interface_digest }

let module_path t = t.module_path
let declaration_name t = t.declaration_name
let interface_digest t = t.interface_digest
let compare = Stdlib.compare
let equal a b = compare a b = 0

let to_string t = String.concat "." (t.module_path @ [ t.declaration_name ])
