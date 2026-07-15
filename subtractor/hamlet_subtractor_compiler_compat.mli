type refusal =
  | Dependency_scan
  | Unsupported_tool of string
  | Typing_failed of typing_failure
  | Probe_lookup_failed of Hamlet_subtractor_probe.lookup_error list
  | Evidence_failed of Hamlet_subtractor_compiler_evidence.refusal
  | Generic_evidence_failed of
      Hamlet_subtractor_compiler_evidence.generic_refusal
  | Request_context_mismatch of {
      field : string;
      expected : string;
      actual : string;
    }
  | Probe_ast_failed of string
  | Protocol_construction_failed of
      Hamlet_subtractor_core.Protocol.construction_error
  | Protocol_correlation_failed of
      Hamlet_subtractor_core.Protocol.correlation_error

and typing_failure = { message : string; location : Location.t option }

type observation = {
  structure_items : int;
  links : Hamlet_subtractor_probe.typed_observation list;
}

type elaboration = {
  engine : Hamlet_subtractor_engine.t;
  generic_definitions :
    Hamlet_subtractor_compiler_evidence.generic_definition list;
  generic_calls : Hamlet_subtractor_compiler_evidence.generic_call list;
}

type request_context = {
  context_fingerprint : string;
  include_dirs : string list;
  hidden_include_dirs : string list;
  visible_paths : string list;
  hidden_paths : string list;
  opens : string list;
  package_mode : Hamlet_subtractor_core.Protocol.package_mode;
  compiler_flags : Hamlet_subtractor_core.Protocol.compiler_flags;
  tool_context : Hamlet_subtractor_core.Protocol.tool_context;
}

(** Snapshot only fields carried by the standard PPX context and derive a
    tool-name-independent semantic fingerprint for the live probe AST. *)
val request_context :
  source_file:string -> Ppxlib.Parsetree.structure -> request_context

(** Type and normalize a probe in an isolated compiler-libs session.

    [tool_name] must come from the active PPX expansion context. The exposed
    observation contains no Typedtree or compiler type nodes. *)
val inspect_probe :
  tool_name:string ->
  source_file:string ->
  Ppxlib.Parsetree.structure ->
  (observation, refusal) result

(** Resolve the canonical probe and run the compiler-free deterministic engine
    before the fresh typing session is reset. *)
val resolve_prepared :
  tool_name:string ->
  source_file:string ->
  Hamlet_subtractor_probe.prepared ->
  (Hamlet_subtractor_engine.t, refusal) result

val elaborate_prepared :
  tool_name:string ->
  source_file:string ->
  Hamlet_subtractor_probe.prepared ->
  (elaboration, refusal) result

(** Resolve an already prepared binary Parsetree in the compiler context carried
    by the versioned request. This never reparses source or reruns a PPX. *)
val resolve_request :
  Hamlet_subtractor_core.Protocol.request ->
  (Hamlet_subtractor_core.Protocol.response, refusal) result
