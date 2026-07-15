(** Exactness certificate for both Hamlet channels. A marker may be resolvable
    on its target channel while an opposite channel remains opaque for later
    dependent markers. Catch and provide composition preserve that distinction.
*)
type opacity = Unproven_origin | Opaque_recovery | Opaque_handler

type evidence
type evidence_view = Exact_proof of Proof.t | Opaque_reasons of opacity list
type t

type validation_error =
  | Wrong_channel of { expected : Kind.t; actual : Kind.t }
  | Input_proof_mismatch of Kind.t
  | Contributing_proof_mismatch of Kind.t
  | Conflicting_exact_proofs of Kind.t

val exact : Proof.t -> evidence
val opaque : opacity -> evidence
val opaque_many : opacity list -> evidence option
val evidence_view : evidence -> evidence_view

val create :
  errors:evidence -> requirements:evidence -> (t, validation_error) result

val errors : t -> evidence
val requirements : t -> evidence

(** Combine evidence on one channel using the same normalization and conflict
    checks as whole-certificate composition. *)
val union :
  kind:Kind.t ->
  operation:Proof.composition ->
  inputs:Marker.id list ->
  evidence list ->
  (evidence, validation_error) result

val chain : inputs:Marker.id list -> t list -> (t, validation_error) result

val recover :
  inputs:Marker.id list ->
  source:t ->
  recoveries:t list ->
  (t, validation_error) result

val with_errors : source:t -> errors:evidence -> (t, validation_error) result

val with_requirements :
  source:t -> requirements:evidence -> (t, validation_error) result

val catch :
  inputs:Marker.id list ->
  source:t ->
  error_result:Residual.t ->
  recoveries:t list ->
  (t, validation_error) result

val provide :
  inputs:Marker.id list ->
  source:t ->
  requirement_result:Residual.t ->
  handlers:t list ->
  (t, validation_error) result

val compare : t -> t -> int
val equal : t -> t -> bool
