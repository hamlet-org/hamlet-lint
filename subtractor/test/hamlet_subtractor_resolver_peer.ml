module Protocol = Hamlet_subtractor_core.Protocol

let read_all () =
  let buffer = Buffer.create 4096 in
  let bytes = Bytes.create 65536 in
  let rec loop () =
    match input stdin bytes 0 (Bytes.length bytes) with
    | 0 -> Buffer.contents buffer
    | count ->
        Buffer.add_subbytes buffer bytes 0 count;
        loop ()
  in
  loop ()

let write payload =
  Hamlet_subtractor_resolver_protocol.encode_frame payload
  |> output_string stdout;
  flush stdout

let response payload =
  `Assoc
    [
      ("protocol", `String "hamlet-subtractor-resolver-output");
      ("version", `Int 1);
      ("kind", `String "response");
      ("payload", `String payload);
    ]
  |> Yojson.Basic.to_string
  |> write

let request () =
  let framed = read_all () in
  let payload =
    Hamlet_subtractor_resolver_protocol.decode_frame
      ~max_payload:(4 * 1024 * 1024)
      framed
    |> Result.get_ok
  in
  Protocol.decode_request payload |> Result.get_ok

let () =
  match Array.to_list Sys.argv with
  | [ _; "crash" ] ->
      ignore (read_all ());
      exit 17
  | [ _; "timeout" ] ->
      ignore (read_all ());
      Unix.sleepf 2.
  | [ _; "close-input" ] ->
      close_in_noerr stdin;
      Unix.sleepf 0.1
  | [ _; "oversized-response" ] ->
      ignore (read_all ());
      String.make 1024 'x' |> output_string stdout;
      flush stdout
  | [ _; "oversized-stderr" ] ->
      ignore (read_all ());
      String.make 1024 'x' |> output_string stderr;
      flush stderr
  | [ _; "unexpected-stderr" ] ->
      ignore (read_all ());
      output_string stderr "resolver warning";
      flush stderr
  | [ _; "malformed" ] ->
      ignore (read_all ());
      write "not-json"
  | [ _; "version" ] ->
      ignore (read_all ());
      response {|{"protocol":"hamlet-subtractor-resolution","version":999}|}
  | [ _; "context" ] ->
      let request = request () in
      let response =
        Protocol.response
          ~request_id:(Protocol.request_id request)
          ~context_fingerprint:"wrong-context"
          ~ast_digest:(Protocol.probe_ast request).digest []
        |> Result.get_ok
      in
      Hamlet_subtractor_resolver_protocol.Response response
      |> Hamlet_subtractor_resolver_protocol.encode_output
      |> write
  | [ _; (("typing-request" | "typing-context" | "typing-ast") as mode) ] ->
      let request = request () in
      let request_id =
        if String.equal mode "typing-request" then "wrong-request"
        else Protocol.request_id request
      in
      let context_fingerprint =
        if String.equal mode "typing-context" then "wrong-context"
        else Protocol.request_context_fingerprint request
      in
      let ast_digest =
        if String.equal mode "typing-ast" then "wrong-ast"
        else (Protocol.probe_ast request).digest
      in
      Hamlet_subtractor_resolver_protocol.Typing_failure
        {
          request_id;
          context_fingerprint;
          ast_digest;
          message = "typing failed";
          location = None;
        }
      |> Hamlet_subtractor_resolver_protocol.encode_output
      |> write
  | _ -> exit 64
