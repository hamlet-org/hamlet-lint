open Types

let rec variant_labels (ty : type_expr) =
  let ty = Ctype.expand_head Env.empty ty in
  match Types.get_desc ty with
  | Tpoly (body, _) -> variant_labels body
  | Tvariant row ->
      let from_fields =
        Types.row_fields row
        |> List.filter_map (fun (label, field) ->
            match Types.row_field_repr field with
            | Rpresent _ | Reither (_, _, _) -> Some label
            | Rabsent -> None)
      in
      from_fields @ variant_labels (Types.row_more row)
  | _ -> []

let present_variant_labels = variant_labels
