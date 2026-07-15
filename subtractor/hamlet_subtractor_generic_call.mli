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
