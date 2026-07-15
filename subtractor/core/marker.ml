type id = string

type t = { id : id; kind : Kind.t; span : Source_span.t }
type id_error = Empty_id | Surrounding_whitespace

let id_of_string value =
  let trimmed = String.trim value in
  if trimmed = "" then Error Empty_id
  else if trimmed <> value then Error Surrounding_whitespace
  else Ok value

let id_to_string id = id
let compare_id = String.compare
let make ~id ~kind ~span = { id; kind; span }
let id t = t.id
let kind t = t.kind
let span t = t.span
let compare = Stdlib.compare
let equal a b = compare a b = 0
