open Hamlet_subtractor_core

type error =
  | Missing_outcome of string
  | Missing_certificate of Marker.id
  | Missing_owner of Marker.id
  | Duplicate_owner of Marker.id
  | Missing_upstream of Marker.id
  | Duplicate_upstream of Marker.id
  | Missing_marker_case of Marker.id
  | Duplicate_marker_case of Marker.id
  | Refused of Diagnostic.t
  | Generation_failed of Marker.t * Hamlet_subtractor_generator.error
  | Unmaterializable_certificate of Marker.t * Leaf.t

val error_message : error -> string

(** Replace every canonical probe marker case with final generated cases and
    constrain each owning combinator result to its resolved effect certificate.
    User cases, attributes on the owner expression, and source locations retain
    their original placement. All internal probe attributes are removed from the
    returned structure. *)
val structure :
  catalogues:Hamlet_subtractor_catalogue.t list ->
  outcomes:Hamlet_subtractor_engine.marker_outcome list ->
  resolved_values:(Marker.t * Hamlet_subtractor_engine.resolved) list ->
  Ppxlib.Parsetree.structure ->
  (Ppxlib.Parsetree.structure, error) result

(** Remove every internal probe-linkage attribute without changing the
    surrounding AST. This is used for dependency scans that deliberately skip
    exact elaboration. *)
val strip_probe_attributes :
  Ppxlib.Parsetree.structure -> Ppxlib.Parsetree.structure
