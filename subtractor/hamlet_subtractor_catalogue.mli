open Hamlet_subtractor_core

(** Compiler-free evidence for one generated [Errors.Cases] catalogue. The field
    order is the producer declaration order. *)
type field = { name : string; leaf : Identity.t }

type t

type validation_error =
  | Empty_catalogue
  | Empty_field_name of Identity.t
  | Duplicate_field_name of string
  | Duplicate_leaf of Identity.t

val create :
  identity:Identity.t ->
  union:Identity.t ->
  fields:field list ->
  (t, validation_error) result

val identity : t -> Identity.t
val union : t -> Identity.t
val fields : t -> field list
val to_protocol : t -> Hamlet_subtractor_core.Protocol.catalogue
val of_protocol : Hamlet_subtractor_core.Protocol.catalogue -> t
val compare : t -> t -> int
val equal : t -> t -> bool
