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

let header_size = 9

let encode_frame payload =
  Printf.sprintf "%08x\n%s" (String.length payload) payload

let decode_frame ~max_payload input =
  if String.length input < header_size then Error Missing_header
  else if input.[8] <> '\n' then Error Malformed_header
  else
    let length =
      try Some (int_of_string ("0x" ^ String.sub input 0 8)) with _ -> None
    in
    match length with
    | None -> Error Malformed_header
    | Some 0 -> Error Empty_frame
    | Some actual when actual > max_payload ->
        Error (Frame_too_large { limit = max_payload; actual })
    | Some expected ->
        let actual = String.length input - header_size in
        if actual < expected then Error (Truncated_frame { expected; actual })
        else if actual > expected then Error Trailing_data
        else Ok (String.sub input header_size expected)

let span_to_json span =
  `Assoc
    [
      ("file", `String (Source_span.file span));
      ("start_offset", `Int (Source_span.start_offset span));
      ("end_offset", `Int (Source_span.end_offset span));
      ("start_line", `Int (Source_span.start_line span));
      ("start_column", `Int (Source_span.start_column span));
      ("end_line", `Int (Source_span.end_line span));
      ("end_column", `Int (Source_span.end_column span));
    ]

let encode_output output =
  let fields =
    match output with
    | Response response ->
        [
          ("kind", `String "response");
          ("payload", `String (Protocol.encode response));
        ]
    | Typing_failure failure ->
        [
          ("kind", `String "typing_failure");
          ("request_id", `String failure.request_id);
          ("context_fingerprint", `String failure.context_fingerprint);
          ("ast_digest", `String failure.ast_digest);
          ("message", `String failure.message);
          ( "location",
            match failure.location with
            | None -> `Null
            | Some span -> span_to_json span );
        ]
  in
  `Assoc
    (("protocol", `String "hamlet-subtractor-resolver-output")
    :: ("version", `Int 1)
    :: fields)
  |> Yojson.Basic.to_string

let malformed_output message = Error (Malformed_output message)

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> malformed_output ("missing field " ^ name)

let string_field name fields =
  match field name fields with
  | Error _ as error -> error
  | Ok (`String value) -> Ok value
  | Ok _ -> malformed_output ("field " ^ name ^ " must be a string")

let int_field name fields =
  match field name fields with
  | Error _ as error -> error
  | Ok (`Int value) -> Ok value
  | Ok _ -> malformed_output ("field " ^ name ^ " must be an integer")

let span_of_json = function
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let* file = string_field "file" fields in
      let* start_offset = int_field "start_offset" fields in
      let* end_offset = int_field "end_offset" fields in
      let* start_line = int_field "start_line" fields in
      let* start_column = int_field "start_column" fields in
      let* end_line = int_field "end_line" fields in
      let* end_column = int_field "end_column" fields in
      Source_span.make ~file ~start_offset ~end_offset ~start_line ~start_column
        ~end_line ~end_column
      |> Result.map_error (fun _ -> Malformed_output "invalid source location")
  | _ -> malformed_output "location must be an object or null"

let decode_output input =
  try
    match Yojson.Basic.from_string input with
    | `Assoc fields ->
        let ( let* ) = Result.bind in
        let* protocol = string_field "protocol" fields in
        if not (String.equal protocol "hamlet-subtractor-resolver-output") then
          malformed_output "unexpected output protocol"
        else
          let* version = int_field "version" fields in
          if version <> 1 then malformed_output "unsupported output version"
          else
            let* kind = string_field "kind" fields in
            begin match kind with
            | "response" ->
                let* payload = string_field "payload" fields in
                Protocol.decode payload
                |> Result.map (fun response -> Response response)
                |> Result.map_error (fun error -> Response_decode error)
            | "typing_failure" ->
                let* request_id = string_field "request_id" fields in
                let* context_fingerprint =
                  string_field "context_fingerprint" fields
                in
                let* ast_digest = string_field "ast_digest" fields in
                let* message = string_field "message" fields in
                let* location_json = field "location" fields in
                let* location =
                  match location_json with
                  | `Null -> Ok None
                  | json -> span_of_json json |> Result.map Option.some
                in
                Ok
                  (Typing_failure
                     {
                       request_id;
                       context_fingerprint;
                       ast_digest;
                       message;
                       location;
                     })
            | _ -> malformed_output "unknown output kind"
            end
    | _ -> malformed_output "output envelope must be an object"
  with Yojson.Json_error message -> malformed_output message

let output_decode_error_message = function
  | Malformed_output message -> "malformed resolver output: " ^ message
  | Response_decode (Protocol.Version_mismatch { expected; actual }) ->
      Printf.sprintf "resolver response version mismatch: expected %d, got %d"
        expected actual
  | Response_decode (Protocol.Malformed { path; message }) ->
      let path = match path with [] -> "$" | path -> String.concat "." path in
      Printf.sprintf "malformed resolver response at %s: %s" path message

let handle ~max_request ~max_response ~resolve input =
  match decode_frame ~max_payload:max_request input with
  | Error error -> Error (Framing error)
  | Ok payload -> (
      match Protocol.decode_request payload with
      | Error error -> Error (Decode error)
      | Ok request -> (
          match resolve request with
          | Error message -> Error (Resolution_failed message)
          | Ok response -> (
              match Protocol.validate_response ~request ~response with
              | Error error -> Error (Correlation error)
              | Ok () ->
                  let payload = Protocol.encode response in
                  if String.length payload > max_response then
                    Error
                      (Framing
                         (Frame_too_large
                            {
                              limit = max_response;
                              actual = String.length payload;
                            }))
                  else Ok (encode_frame payload))))

let message = function
  | Framing Missing_header -> "resolver frame header is incomplete"
  | Framing Malformed_header -> "resolver frame header is malformed"
  | Framing Empty_frame -> "resolver request frame is empty"
  | Framing (Frame_too_large { limit; actual }) ->
      Printf.sprintf "resolver frame is too large: %d bytes exceeds %d" actual
        limit
  | Framing (Truncated_frame { expected; actual }) ->
      Printf.sprintf "resolver frame is truncated: expected %d bytes, got %d"
        expected actual
  | Framing Trailing_data ->
      "resolver accepts exactly one request frame per invocation"
  | Decode (Protocol.Version_mismatch { expected; actual }) ->
      Printf.sprintf "resolver protocol version mismatch: expected %d, got %d"
        expected actual
  | Decode (Protocol.Malformed { path; message }) ->
      let path = match path with [] -> "$" | _ -> String.concat "." path in
      Printf.sprintf "malformed resolver request at %s: %s" path message
  | Resolution_failed message -> "resolver failed: " ^ message
  | Correlation (Protocol.Context_fingerprint_mismatch _) ->
      "resolver response context fingerprint does not match the request"
  | Correlation (Protocol.Request_id_mismatch _) ->
      "resolver response request identity does not match the request"
  | Correlation (Protocol.Ast_digest_mismatch _) ->
      "resolver response AST digest does not match the request"
  | Correlation (Protocol.Missing_marker_result id) ->
      "resolver response is missing marker " ^ Marker.id_to_string id
  | Correlation (Protocol.Unexpected_marker_result id) ->
      "resolver response contains unexpected marker " ^ Marker.id_to_string id
  | Correlation (Protocol.Marker_mismatch { expected; _ }) ->
      "resolver response changed marker metadata for "
      ^ Marker.id_to_string (Marker.id expected)
  | Correlation (Protocol.Missing_generic_attachment id) ->
      "resolver response is missing generic attachment " ^ id
  | Correlation (Protocol.Unexpected_generic_attachment id) ->
      "resolver response contains unexpected generic attachment " ^ id
  | Correlation (Protocol.Generic_attachment_kind_mismatch { id; _ }) ->
      "resolver response changed generic attachment kind for " ^ id
