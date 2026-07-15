type call = {
  id : string;
  loc : Ppxlib.Location.t;
  callee_loc : Ppxlib.Location.t;
}

type refusal_reason = Legacy_forward_extension
type refusal = { loc : Ppxlib.Location.t; reason : refusal_reason }

type prepared = {
  base_structure : Ppxlib.Parsetree.structure;
  probe_structure : Ppxlib.Parsetree.structure;
  calls : call list;
  refusals : refusal list;
}

(** Link plausible direct calls in the temporary probe. The resolver classifies
    each call from compiler identities; ordinary calls are left unchanged. *)
val prepare : Ppxlib.Parsetree.structure -> prepared

val call_attribute : string
val callee_attribute : string
val source_attribute : string
val specialized_attribute : string

val expectations :
  prepared ->
  (Hamlet_subtractor_core.Protocol.generic_expectation list, string) result

val refusal_message : refusal_reason -> string

type finalization_error =
  | Missing_attachment of string
  | Duplicate_attachment of string
  | Invalid_attachment of string
  | Contract_evaluation_failed of string
  | Generation_failed of Hamlet_subtractor_generator.error
  | Missing_call of string
  | Duplicate_call of string

val finalization_error_message : finalization_error -> string

val finalize :
  calls:call list ->
  attachments:Hamlet_subtractor_core.Protocol.generic_attachment list ->
  catalogues:Hamlet_subtractor_catalogue.t list ->
  Ppxlib.Parsetree.structure ->
  (Ppxlib.Parsetree.structure, finalization_error) result
