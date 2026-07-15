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
val provisional_attribute_name : string
val retained_attribute_name : string
val schema_version : int
val companion_name : string -> string
val encode_provisional : t -> (string, string) result
val decode_provisional : string -> (t, string) result

val definition_expectations :
  Ppxlib.Parsetree.structure ->
  (Hamlet_subtractor_core.Protocol.generic_expectation list, string) result

val finalize_definitions :
  attachments:Hamlet_subtractor_core.Protocol.generic_attachment list ->
  Ppxlib.Parsetree.structure ->
  (Ppxlib.Parsetree.structure, string) result
