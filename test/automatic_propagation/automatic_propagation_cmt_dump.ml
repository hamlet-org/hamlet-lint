open Types

module String_set = Set.Make (String)

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.equal prefix (String.sub value 0 prefix_length)

let contains ~needle value =
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec loop index =
    if index + needle_length > value_length then false
    else if String.equal needle (String.sub value index needle_length) then true
    else loop (index + 1)
  in
  loop 0

let strip_current_module ~current path =
  let name = Path.name path in
  let prefix = current ^ "." in
  if has_prefix ~prefix name then
    String.sub name (String.length prefix)
      (String.length name - String.length prefix)
  else name

let rec type_shape ~current seen ty =
  let node = Transient_expr.repr ty in
  if String_set.mem (string_of_int node.id) seen then "..."
  else
    let seen = String_set.add (string_of_int node.id) seen in
    match get_desc ty with
    | Tvar _ -> if node.level = Btype.generic_level then "'a" else "'_a"
    | Tunivar _ -> "'univar"
    | Tconstr (path, [], _) -> strip_current_module ~current path
    | Tconstr (path, arguments, _) ->
        let arguments =
          arguments |> List.map (type_shape ~current seen) |> String.concat ","
        in
        Printf.sprintf "%s<%s>" (strip_current_module ~current path) arguments
    | Ttuple elements ->
        elements
        |> List.map (fun (_, element) -> type_shape ~current seen element)
        |> String.concat "*"
        |> Printf.sprintf "(%s)"
    | Tarrow (_, argument, result, _) ->
        Printf.sprintf "(%s->%s)"
          (type_shape ~current seen argument)
          (type_shape ~current seen result)
    | Tpoly (body, _) -> type_shape ~current seen body
    | Tvariant row -> row_shape ~current seen row
    | Tpackage _ -> "module"
    | Tobject _ -> "object"
    | Tfield _ -> "field"
    | Tnil -> "nil"
    | Tlink linked -> type_shape ~current seen linked
    | Tsubst (substitution, _) -> type_shape ~current seen substitution
    | _ -> "opaque"

and row_shape ~current seen row =
  let (Row { fields; more; closed; fixed; name = _ }) = row_repr row in
  let fields =
    fields
    |> List.filter_map (fun (label, field) ->
        match row_field_repr field with
        | Rpresent None -> Some label
        | Rpresent (Some payload) ->
            Some
              (Printf.sprintf "%s(%s)" label (type_shape ~current seen payload))
        | Reither _ -> Some (label ^ "(?)")
        | Rabsent -> None)
    |> List.sort String.compare
    |> String.concat ","
  in
  let openness =
    match (closed, fixed, get_desc more) with
    | true, None, Tnil -> "closed"
    | false, None, Tvar _
      when (Transient_expr.repr more).level = Btype.generic_level ->
        "principal"
    | _, Some _, _ -> "fixed"
    | _ -> "unresolved"
  in
  Printf.sprintf "%s[%s]" openness fields

let effect_slots env ty =
  let rec find ty =
    match get_desc ty with
    | Tpoly (body, _) -> find body
    | Tconstr (_, [ result; errors; requirements ], _) ->
        Some (result, errors, requirements)
    | Tlink linked -> find linked
    | _ ->
        let expanded = Ctype.expand_head env ty in
        if expanded == ty then None else find expanded
  in
  find ty

let slot_shape ~current env ty =
  let expanded = Ctype.expand_head env ty in
  match get_desc expanded with
  | Tvar _ when (Transient_expr.repr expanded).level = Btype.generic_level ->
      "polymorphic"
  | Tconstr (path, [], _) when String.equal (Path.last path) "t" ->
      let name = Path.name path in
      if contains ~needle:"Never" name then "never"
      else type_shape ~current String_set.empty expanded
  | Tvariant row -> row_shape ~current String_set.empty row
  | _ -> type_shape ~current String_set.empty expanded

let dump_value ~current env identifier description =
  let name = Ident.name identifier in
  if has_prefix ~prefix:"case_" name then
    match effect_slots env description.val_type with
    | Some (result, errors, requirements) ->
        Printf.printf "%s result=%s errors=%s requirements=%s\n" name
          (type_shape ~current String_set.empty result)
          (slot_shape ~current env errors)
          (slot_shape ~current env requirements)
    | None -> Printf.printf "%s not-an-effect\n" name

let dump_structure cmt structure =
  List.iter
    (function
      | Sig_value (identifier, description, Exported) ->
          dump_value ~current:cmt.Cmt_format.cmt_modname
            structure.Typedtree.str_final_env identifier description
      | _ -> ())
    structure.Typedtree.str_type

let () =
  if Array.length Sys.argv <> 2 then
    invalid_arg "usage: automatic_propagation_cmt_dump CMT";
  let cmt = Cmt_format.read_cmt Sys.argv.(1) in
  match cmt.cmt_annots with
  | Implementation structure -> dump_structure cmt structure
  | _ -> failwith "expected an implementation CMT"
