type payload = No_payload | Payload of Type_identity.t

type t = {
  kind : Kind.t;
  declaration : Identity.t;
  label : string;
  payload : payload;
}

type validation_error = Empty_label

let make ~kind ~declaration ~label ~payload =
  if String.trim label = "" then Error Empty_label
  else Ok { kind; declaration; label; payload }

let error ~declaration ~label ~payload =
  make ~kind:Kind.Error ~declaration ~label ~payload

let requirement ~declaration ~label ~payload =
  make ~kind:Kind.Requirement ~declaration ~label ~payload

let kind t = t.kind
let declaration t = t.declaration
let label t = t.label
let payload t = t.payload
let payload_arity t = match t.payload with No_payload -> 0 | Payload _ -> 1
let compare = Stdlib.compare
let equal a b = compare a b = 0

let compare_structural a b =
  Stdlib.compare (a.kind, a.label, a.payload) (b.kind, b.label, b.payload)

let equal_structural a b = compare_structural a b = 0

let to_string t =
  match t.payload with
  | No_payload -> "`" ^ t.label
  | Payload payload ->
      Printf.sprintf "`%s of %s" t.label (Type_identity.to_string payload)
