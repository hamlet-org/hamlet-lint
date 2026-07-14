open Hamlet_subtractor_core

(** Exact marker output retained for dependent elaboration. [residual] is the
    target-channel projection used for final code generation. [certificate]
    preserves both Hamlet channels. *)
type resolved = { residual : Residual.t; certificate : Effect_certificate.t }

(** A compiler-free typed backend. Implementations may close over private
    compiler state in ['context], but no compiler value crosses this API. *)
type 'context typed_backend = {
  dependencies :
    'context -> Marker.t -> (Marker.id list, Diagnostic.code) result;
  resolve :
    'context ->
    marker:Marker.t ->
    dependencies:(Marker.t * resolved) list ->
    (resolved, Diagnostic.code) result;
}

type marker_outcome = Marker.t * Protocol.outcome

type t

type error = Duplicate_marker of Marker.id

(** Resolve all markers in stable marker-ID order. Refused dependencies make a
    consumer opaque. Strongly connected dependency components receive a
    deterministic recursive-dependency diagnostic. No result survives this call
    in a persistent cache. *)
val elaborate :
  backend:'context typed_backend ->
  context:'context ->
  catalogues:Hamlet_subtractor_catalogue.t list ->
  markers:Marker.t list ->
  (t, error) result

val outcomes : t -> marker_outcome list
val catalogues : t -> Hamlet_subtractor_catalogue.t list
val resolved_values : t -> (Marker.t * resolved) list

(** Rehydrate a fully validated resolver response without retaining compiler
    values. Protocol construction guarantees one certificate per resolution. *)
val of_response : Protocol.response -> t
