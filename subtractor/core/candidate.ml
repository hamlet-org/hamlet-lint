type t = { declared : Observation.t; upstream : Observation.t }

type validation_error =
  | Kind_mismatch of { declared : Kind.t; upstream : Kind.t }

let create ~declared ~upstream =
  let declared_kind = Observation.kind declared in
  let upstream_kind = Observation.kind upstream in
  if Kind.equal declared_kind upstream_kind then Ok { declared; upstream }
  else
    Error (Kind_mismatch { declared = declared_kind; upstream = upstream_kind })

let kind t = Observation.kind t.declared
let declared t = t.declared
let upstream t = t.upstream

let extra t =
  let upstream = Observation.tags t.upstream in
  t.declared
  |> Observation.tags
  |> List.filter (fun tag -> not (List.mem tag upstream))
