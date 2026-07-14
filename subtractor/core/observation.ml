type t = { kind : Kind.t; tags : string list }

let append_unique current additions =
  List.fold_left
    (fun acc tag -> if List.mem tag acc then acc else acc @ [ tag ])
    current additions

let of_tags ~kind tags = { kind; tags }
let kind t = t.kind
let tags t = t.tags
let add_tags t tags = { t with tags = append_unique t.tags tags }

let subtract t ~handled =
  { t with tags = List.filter (fun tag -> not (List.mem tag handled)) t.tags }

let union first second =
  if Kind.equal first.kind second.kind then Some (add_tags first second.tags)
  else None

let compare = Stdlib.compare
let equal a b = compare a b = 0
