open Ppxlib

type error =
  | Ast_serialization_failed of string
  | Protocol_construction_failed of
      Hamlet_subtractor_core.Protocol.construction_error
  | Transport_failed of Hamlet_subtractor_resolver_transport.error

(** Serialize a probe with the compiler binary AST format for the dynamic extent
    of [f]. The file is always removed, including after child failure. *)
val with_serialized_probe :
  source_file:string ->
  Parsetree.structure ->
  (Hamlet_subtractor_core.Protocol.ast_descriptor -> 'a) ->
  ('a, error) result

val resolve_prepared :
  ?program:string ->
  ?limits:Hamlet_subtractor_resolver_transport.limits ->
  tool_name:string ->
  source_file:string ->
  Hamlet_subtractor_probe.prepared ->
  (Hamlet_subtractor_engine.t, error) result

val message : error -> string
