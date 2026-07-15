open Hamlet_subtractor_core

type error =
  | Missing_catalogue of Identity.t
  | Conflicting_catalogue of Identity.t
  | Invalid_materialization of Leaf.t

val error_message : error -> string

(** Generate the final propagation cases at the marker location. A ghost
    wildcard refutation validates that the generated forwarding cases cover the
    final compiler's input type. A fully exhausted residual adds the existing
    redundant wildcard after that refutation so OCaml warning 11 remains
    visible. The refutation detects underapproximation only. Exact evidence is
    still responsible for preventing overapproximation. *)
val cases :
  loc:Ppxlib.Location.t ->
  catalogues:Hamlet_subtractor_catalogue.t list ->
  Residual.t ->
  (Ppxlib.Parsetree.case list, error) result
