open Hamlet_subtractor_core

type framing_error =
  | Missing_header
  | Malformed_header
  | Empty_frame
  | Frame_too_large of { limit : int; actual : int }
  | Truncated_frame of { expected : int; actual : int }
  | Trailing_data

type error =
  | Framing of framing_error
  | Decode of Protocol.decode_error
  | Resolution_failed of string
  | Correlation of Protocol.correlation_error

type remote_failure = {
  request_id : string;
  context_fingerprint : string;
  ast_digest : string;
  message : string;
  location : Source_span.t option;
}

type output = Response of Protocol.response | Typing_failure of remote_failure

type output_decode_error =
  | Malformed_output of string
  | Response_decode of Protocol.decode_error

(** A frame has an eight-digit hexadecimal payload length, one newline, and the
    exact payload bytes. *)
val encode_frame : string -> string

val decode_frame : max_payload:int -> string -> (string, framing_error) result

(** Encode or decode the lockstep child result envelope. Typing failures are
    successful process responses so their original source location survives
    process isolation. *)
val encode_output : output -> string

val decode_output : string -> (output, output_decode_error) result
val output_decode_error_message : output_decode_error -> string

(** Process exactly one bounded request frame and produce one response frame. *)
val handle :
  max_request:int ->
  max_response:int ->
  resolve:(Protocol.request -> (Protocol.response, string) result) ->
  string ->
  (string, error) result

val message : error -> string
