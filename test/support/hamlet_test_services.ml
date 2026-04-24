(** Shared [%%hamlet.service] service declarations used across multiple test
    suites (ppx_test, ppx_expansion_test, ...). Each declaration expands into a
    wrapper module with [Errors], [S], [Make], [Tag]. *)

(* The PPX expands each [%%hamlet.service] block into a wrapper module that
   starts with `open! Hamlet`, so no top-level open is needed here. *)

[%%hamlet.service
module type Console = sig
  type console_error = [ `Console_error of string ]
  val print_endline : string -> (unit, [> console_error ], 'r) t
  val read_line : unit -> (string, [> console_error ], 'r) t
end]

[%%hamlet.service
module type Logger = sig
  type logger_error = [ `Logger_error of string ]
  val log : level:string -> string -> (unit, [> logger_error ], 'r) t
end]

[%%hamlet.service
module type Foo = sig
  type foo_error_alpha = [ `Foo_error_alpha of string ]
  type foo_error_beta = [ `Foo_error_beta of int ]
  val foo_method : unit -> (unit, [> foo_error_alpha | foo_error_beta ], 'r) t
end]

(* service with multiple error types *)
[%%hamlet.service
module type Database = sig
  type connection_error = [ `Connection_error of string ]
  type query_error = [ `Query_error of string ]
  val connect : string -> (unit, [> connection_error ], 'r) t
  val query : string -> (string list, [> query_error ], 'r) t
end]

(* service with a no-payload error variant *)
[%%hamlet.service
module type Cache = sig
  type cache_miss = [ `Cache_miss ]
  val get : string -> (string, [> cache_miss ], 'r) t
end]

(* The RemoteCache service lives in [remote_cache.ml] (own file, so the
   cross-CU tests really exercise cross-CU propagate_e rather than a same-CU
   unfolding). Re-exported here via [include] so consumers can reach it at
   [Hamlet_test_services.RemoteCache] and the consumer PPX's Rest-path
   computation (replace-last-segment of the service longident) lands on
   [Hamlet_test_services.__Hamlet_rest_RemoteCache__], which [include]
   pulls in at the same level. *)
include Remote_cache

(* MetricsSink: a SECOND cross-CU service, also in its own file. The
   multi-service test builds a match whose propagate_e must resolve BOTH
   the RemoteCache and the MetricsSink rest aliases simultaneously. *)
include Metrics_sink
