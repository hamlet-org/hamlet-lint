open Hamlet_subtractor_core

type error = Hamlet_subtractor_generator.error

(** Generate one exhaustive result-polymorphic evidence slot. Leaves claimed by
    the helper are routed to [handled]; every other proven input leaf is routed
    to [forward]. *)
val slot :
  loc:Ppxlib.Location.t ->
  catalogues:Hamlet_subtractor_catalogue.t list ->
  input:Proof.t ->
  claimed:Leaf.t list ->
  (Ppxlib.Parsetree.expression, error) result

(** Preserve dependency order: one slot stays bare, while several slots use a
    tuple matching the transformed helper ABI. *)
val bundle :
  loc:Ppxlib.Location.t ->
  Ppxlib.Parsetree.expression list ->
  Ppxlib.Parsetree.expression
