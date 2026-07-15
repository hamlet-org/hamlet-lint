type call = {
  id : string;
  loc : Ppxlib.Location.t;
  callee_loc : Ppxlib.Location.t;
  source_loc : Ppxlib.Location.t;
  placeholder_loc : Ppxlib.Location.t;
}

type refusal_reason =
  | Not_a_final_argument
  | Labelled_argument
  | Missing_effect_argument
  | Multiple_placeholders
  | Pipeline_application

type refusal = { loc : Ppxlib.Location.t; reason : refusal_reason }

type prepared = {
  base_structure : Ppxlib.Parsetree.structure;
  probe_structure : Ppxlib.Parsetree.structure;
  calls : call list;
  refusals : refusal list;
}

(** Find explicit generic-helper call sites and replace their final forwarding
    argument with a bottom expression in the temporary probe. *)
val prepare : Ppxlib.Parsetree.structure -> prepared

val call_attribute : string
val callee_attribute : string
val source_attribute : string
val placeholder_attribute : string

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
  | Missing_placeholder of string
  | Duplicate_placeholder of string

val finalization_error_message : finalization_error -> string

val finalize :
  calls:call list ->
  attachments:Hamlet_subtractor_core.Protocol.generic_attachment list ->
  catalogues:Hamlet_subtractor_catalogue.t list ->
  Ppxlib.Parsetree.structure ->
  (Ppxlib.Parsetree.structure, finalization_error) result
