type slot_kind = Error | Requirement
type owner_form = Direct | Pipe

type slot = {
  ordinal : int;
  marker_id : string;
  kind : slot_kind;
  owner_form : owner_form;
  handled_cases : int;
  guarded : bool;
  handled_digest : string;
}

type t = { helper : string; source_parameter : int; slots : slot list }

val attribute_name : string
val schema_version : int
val companion_name : string -> string
val encode_provisional : t -> (string, string) result
