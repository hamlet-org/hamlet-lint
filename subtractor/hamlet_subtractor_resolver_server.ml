module Protocol = Hamlet_subtractor_core.Protocol
module Source_span = Hamlet_subtractor_core.Source_span

let maximum_request_bytes = (4 * 1024 * 1024) + 9
let maximum_response_bytes = 16 * 1024 * 1024

let read_bounded channel ~limit =
  let buffer = Buffer.create 4096 in
  let bytes = Bytes.create 65536 in
  let rec loop () =
    match input channel bytes 0 (Bytes.length bytes) with
    | 0 -> Ok (Buffer.contents buffer)
    | count ->
        Buffer.add_subbytes buffer bytes 0 count;
        if Buffer.length buffer > limit then
          Error "resolver request exceeds the transport limit"
        else loop ()
  in
  try loop () with exn -> Error (Printexc.to_string exn)

let decode_request framed =
  match
    Hamlet_subtractor_resolver_protocol.decode_frame
      ~max_payload:(maximum_request_bytes - 9)
      framed
  with
  | Error error ->
      Error
        (Hamlet_subtractor_resolver_protocol.message
           (Hamlet_subtractor_resolver_protocol.Framing error))
  | Ok payload -> (
      match Protocol.decode_request payload with
      | Ok request -> Ok request
      | Error (Protocol.Version_mismatch { expected; actual }) ->
          Error
            (Printf.sprintf
               "resolver request version mismatch: expected %d, got %d" expected
               actual)
      | Error (Protocol.Malformed { path; message }) ->
          let path =
            match path with [] -> "$" | path -> String.concat "." path
          in
          Error
            (Printf.sprintf "malformed resolver request at %s: %s" path message)
      )

let compiler_error_message error =
  let open Hamlet_subtractor_compiler_compat in
  match error with
  | Dependency_scan -> "dependency scans cannot invoke the resolver"
  | Unsupported_tool tool -> "unsupported resolver caller " ^ tool
  | Typing_failed failure -> "probe typing failed: " ^ failure.message
  | Probe_lookup_failed _ -> "typed probe marker correlation failed"
  | Evidence_failed refusal ->
      Hamlet_subtractor_compiler_evidence.refusal_message refusal
  | Generic_evidence_failed refusal ->
      "generic helper evidence failed: "
      ^ Hamlet_subtractor_compiler_evidence.generic_refusal_message refusal
  | Request_context_mismatch { field; expected; actual } ->
      Printf.sprintf "resolver context %s mismatch: expected %s, got %s" field
        expected actual
  | Probe_ast_failed detail -> "binary probe AST failed: " ^ detail
  | Protocol_construction_failed _ ->
      "resolver could not construct a complete response"
  | Protocol_correlation_failed _ ->
      "resolver response did not correlate with the request"

let source_span location =
  let start = location.Location.loc_start in
  let finish = location.Location.loc_end in
  if String.trim start.pos_fname = "" then None
  else
    Source_span.make ~file:start.pos_fname ~start_offset:start.pos_cnum
      ~end_offset:finish.pos_cnum ~start_line:start.pos_lnum
      ~start_column:(start.pos_cnum - start.pos_bol)
      ~end_line:finish.pos_lnum
      ~end_column:(finish.pos_cnum - finish.pos_bol)
    |> Result.to_option

let output value =
  let payload = Hamlet_subtractor_resolver_protocol.encode_output value in
  if String.length payload > maximum_response_bytes then
    Error "resolver response exceeds the transport limit"
  else
    try
      Hamlet_subtractor_resolver_protocol.encode_frame payload
      |> output_string stdout;
      flush stdout;
      Ok ()
    with exn -> Error (Printexc.to_string exn)

let run () =
  match read_bounded stdin ~limit:maximum_request_bytes with
  | Error _ as error -> error
  | Ok framed -> (
      match decode_request framed with
      | Error _ as error -> error
      | Ok request -> (
          match Hamlet_subtractor_compiler_compat.resolve_request request with
          | Error (Hamlet_subtractor_compiler_compat.Typing_failed failure) ->
              let remote_failure =
                Hamlet_subtractor_resolver_protocol.
                  {
                    request_id = Protocol.request_id request;
                    context_fingerprint =
                      Protocol.request_context_fingerprint request;
                    ast_digest = (Protocol.probe_ast request).digest;
                    message = failure.message;
                    location = Option.bind failure.location source_span;
                  }
              in
              output
                (Hamlet_subtractor_resolver_protocol.Typing_failure
                   remote_failure)
          | Error error -> Error (compiler_error_message error)
          | Ok response ->
              output (Hamlet_subtractor_resolver_protocol.Response response)))
