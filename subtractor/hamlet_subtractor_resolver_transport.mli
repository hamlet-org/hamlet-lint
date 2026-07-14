open Hamlet_subtractor_core

type limits = {
  request_bytes : int;
  response_bytes : int;
  stderr_bytes : int;
  timeout_seconds : float;
}

type error =
  | Resolver_not_found of string list
  | Unsupported_platform of string
  | Request_too_large of { limit : int; actual : int }
  | Response_too_large of { limit : int; actual : int }
  | Stderr_too_large of { limit : int; actual : int }
  | Spawn_failed of string
  | Io_failed of string
  | Timeout of float
  | Input_closed
  | Process_failed of Unix.process_status * string
  | Unexpected_stderr of string
  | Framing of Hamlet_subtractor_resolver_protocol.framing_error
  | Output_decode of Hamlet_subtractor_resolver_protocol.output_decode_error
  | Remote_typing_failure of Hamlet_subtractor_resolver_protocol.remote_failure
  | Correlation of Protocol.correlation_error

val default_limits : limits

(** Derive resolver candidates from an uninstalled Dune PPX executable. *)
val source_tree_candidates : executable_name:string -> string list

(** Resolve the lockstep executable through the Dune package site, with a
    same-context source-tree fallback. This never searches [PATH]. *)
val find_resolver : unit -> (string, error) result

(** [run_program] is exposed for transport fault-injection tests. Production
    callers use [run], which never searches [PATH]. *)
val run_program :
  ?limits:limits ->
  program:string ->
  arguments:string array ->
  Protocol.request ->
  (Protocol.response, error) result

val run :
  ?limits:limits -> Protocol.request -> (Protocol.response, error) result

val message : error -> string
