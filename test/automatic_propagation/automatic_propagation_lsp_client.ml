open Yojson.Safe

exception Protocol_error of string

let failf format =
  Printf.ksprintf (fun message -> raise (Protocol_error message)) format

let timeout_seconds = 30.

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match assoc_field name json with
  | Some (`String value) -> Some value
  | _ -> None

let int_field name json =
  match assoc_field name json with Some (`Int value) -> Some value | _ -> None

let rec json_strings = function
  | `String value -> [ value ]
  | `Assoc fields ->
      List.concat_map (fun (_, value) -> json_strings value) fields
  | `List values | `Tuple values -> List.concat_map json_strings values
  | `Variant (_, Some value) -> json_strings value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Variant (_, None) -> []

let contains ~needle value =
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec loop offset =
    if offset + needle_length > value_length then false
    else if String.equal needle (String.sub value offset needle_length) then
      true
    else loop (offset + 1)
  in
  loop 0

let assert_no_auto_marker ~context json =
  let text = json_strings json |> String.concat "\n" in
  let markers =
    [ "propagate_e.auto"; "propagate_s.auto"; "hamlet.subtractor.marker" ]
  in
  match List.find_opt (fun marker -> contains ~needle:marker text) markers with
  | None -> ()
  | Some marker ->
      failf "%s exposed automatic marker %s:\n%s" context marker text

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let find_substring_from ~pattern value offset =
  let pattern_length = String.length pattern in
  let value_length = String.length value in
  let rec loop index =
    if index + pattern_length > value_length then None
    else if String.equal pattern (String.sub value index pattern_length) then
      Some index
    else loop (index + 1)
  in
  loop offset

let replace_all ~pattern ~replacement value =
  let pattern_length = String.length pattern in
  let buffer = Buffer.create (String.length value) in
  let rec loop offset replacements =
    match find_substring_from ~pattern value offset with
    | None ->
        Buffer.add_substring buffer value offset (String.length value - offset);
        (Buffer.contents buffer, replacements)
    | Some index ->
        Buffer.add_substring buffer value offset (index - offset);
        Buffer.add_string buffer replacement;
        loop (index + pattern_length) (replacements + 1)
  in
  loop 0 0

let line_of_binding ~binding source =
  let prefix = "let " ^ binding ^ " =" in
  source
  |> String.split_on_char '\n'
  |> List.mapi (fun line text -> (line, text))
  |> List.find_map (fun (line, text) ->
      if String.equal (String.trim text) prefix then Some line else None)
  |> function
  | Some line -> line
  | None -> failf "binding %s was not found" binding

let uri_of_path path =
  let is_unreserved = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/' -> true
    | _ -> false
  in
  let buffer = Buffer.create (String.length path + 8) in
  Buffer.add_string buffer "file://";
  String.iter
    (fun character ->
      if is_unreserved character then Buffer.add_char buffer character
      else
        Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code character)))
    path;
  Buffer.contents buffer

type process = {
  pid : int;
  input : Unix.file_descr;
  output : Unix.file_descr;
  mutable input_open : bool;
  mutable output_open : bool;
}

let close_input process =
  if process.input_open then (
    process.input_open <- false;
    try Unix.close process.input with Unix.Unix_error _ -> ())

let close_output process =
  if process.output_open then (
    process.output_open <- false;
    try Unix.close process.output with Unix.Unix_error _ -> ())

let waitpid_until pid deadline =
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when Unix.gettimeofday () >= deadline -> None
    | 0, _ ->
        ignore (Unix.select [] [] [] 0.05);
        loop ()
    | _, status -> Some status
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 0)
  in
  loop ()

let terminate process =
  close_output process;
  close_input process;
  let status = waitpid_until process.pid (Unix.gettimeofday () +. 1.) in
  match status with
  | Some _ -> ()
  | None -> (
      (try Unix.kill process.pid Sys.sigterm with Unix.Unix_error _ -> ());
      match waitpid_until process.pid (Unix.gettimeofday () +. 2.) with
      | Some _ -> ()
      | None ->
          (try Unix.kill process.pid Sys.sigkill with Unix.Unix_error _ -> ());
          ignore (waitpid_until process.pid (Unix.gettimeofday () +. 2.)))

let launch_server () =
  let server_input, client_output = Unix.pipe ~cloexec:true () in
  let client_input, server_output = Unix.pipe ~cloexec:true () in
  let program =
    match Sys.getenv_opt "OPAM_SWITCH_PREFIX" with
    | Some prefix ->
        let candidate = Filename.concat prefix "bin/ocamllsp" in
        if Sys.file_exists candidate then candidate else "ocamllsp"
    | None -> "ocamllsp"
  in
  let arguments =
    [|
      program; "--stdio"; "--clientProcessId"; string_of_int (Unix.getpid ());
    |]
  in
  let pid =
    try
      Unix.create_process program arguments server_input server_output
        Unix.stderr
    with exception_value ->
      Unix.close server_input;
      Unix.close client_output;
      Unix.close client_input;
      Unix.close server_output;
      raise exception_value
  in
  Unix.close server_input;
  Unix.close server_output;
  {
    pid;
    input = client_input;
    output = client_output;
    input_open = true;
    output_open = true;
  }

let wait_readable descriptor deadline =
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0. then failf "timed out waiting for ocamllsp output";
    match Unix.select [ descriptor ] [] [] remaining with
    | [], _, _ -> failf "timed out waiting for ocamllsp output"
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let read_byte descriptor deadline =
  let byte = Bytes.create 1 in
  let rec loop () =
    wait_readable descriptor deadline;
    match Unix.read descriptor byte 0 1 with
    | 0 -> failf "ocamllsp closed its output"
    | _ -> Bytes.get byte 0
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let read_line descriptor deadline =
  let buffer = Buffer.create 32 in
  let rec loop () =
    match read_byte descriptor deadline with
    | '\n' ->
        let line = Buffer.contents buffer in
        let length = String.length line in
        if length > 0 && Char.equal line.[length - 1] '\r' then
          String.sub line 0 (length - 1)
        else line
    | character ->
        Buffer.add_char buffer character;
        loop ()
  in
  loop ()

let read_exactly descriptor deadline length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then Bytes.unsafe_to_string bytes
    else (
      wait_readable descriptor deadline;
      match Unix.read descriptor bytes offset (length - offset) with
      | 0 -> failf "ocamllsp closed its output inside a packet"
      | read -> loop (offset + read)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset)
  in
  loop 0

let read_packet process deadline =
  let rec headers content_length =
    match read_line process.input deadline with
    | "" -> content_length
    | line -> (
        match String.index_opt line ':' with
        | None -> headers content_length
        | Some colon ->
            let name =
              String.sub line 0 colon |> String.trim |> String.lowercase_ascii
            in
            let value =
              String.sub line (colon + 1) (String.length line - colon - 1)
              |> String.trim
            in
            let content_length =
              if String.equal name "content-length" then
                match int_of_string_opt value with
                | Some value -> Some value
                | None -> failf "invalid Content-Length from ocamllsp: %s" value
              else content_length
            in
            headers content_length)
  in
  match headers None with
  | None -> failf "ocamllsp packet omitted Content-Length"
  | Some length -> read_exactly process.input deadline length |> from_string

let write_all descriptor value =
  let rec loop offset =
    if offset < String.length value then
      match
        Unix.write_substring descriptor value offset
          (String.length value - offset)
      with
      | 0 -> failf "ocamllsp closed its input"
      | written -> loop (offset + written)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
  in
  loop 0

let send_packet process json =
  let body = to_string json in
  let header =
    Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body)
  in
  write_all process.output (header ^ body)

let request ~id ~method_ params =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int id);
      ("method", `String method_);
      ("params", params);
    ]

let notification ~method_ params =
  `Assoc
    [
      ("jsonrpc", `String "2.0"); ("method", `String method_); ("params", params);
    ]

let request_without_params ~id ~method_ =
  `Assoc
    [ ("jsonrpc", `String "2.0"); ("id", `Int id); ("method", `String method_) ]

let notification_without_params ~method_ =
  `Assoc [ ("jsonrpc", `String "2.0"); ("method", `String method_) ]

type session = {
  process : process;
  mutable diagnostic_sequence : int;
  mutable diagnostics : (int * t) list;
}

let respond_to_server_request session packet =
  match assoc_field "id" packet with
  | None -> ()
  | Some id ->
      let result =
        match string_field "method" packet with
        | Some "workspace/configuration" -> `List []
        | _ -> `Null
      in
      send_packet session.process
        (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ])

let receive session deadline =
  let packet = read_packet session.process deadline in
  match string_field "method" packet with
  | Some "textDocument/publishDiagnostics" ->
      let params = Option.value (assoc_field "params" packet) ~default:`Null in
      assert_no_auto_marker ~context:"ocamllsp diagnostics" params;
      session.diagnostic_sequence <- session.diagnostic_sequence + 1;
      session.diagnostics <-
        (session.diagnostic_sequence, params) :: session.diagnostics;
      `Notification
  | Some _ ->
      respond_to_server_request session packet;
      `Notification
  | None -> `Response packet

let response_id packet = int_field "id" packet

let response_result packet =
  match assoc_field "error" packet with
  | Some error ->
      failf "ocamllsp returned an error: %s" (pretty_to_string error)
  | None -> Option.value (assoc_field "result" packet) ~default:`Null

let wait_response session id =
  let deadline = Unix.gettimeofday () +. timeout_seconds in
  let rec loop () =
    match receive session deadline with
    | `Response packet when response_id packet = Some id ->
        response_result packet
    | `Response packet ->
        failf "ocamllsp returned unexpected response: %s"
          (pretty_to_string packet)
    | `Notification -> loop ()
  in
  loop ()

let diagnostic_uri params = string_field "uri" params

let diagnostics_after session ~after ~uri =
  session.diagnostics
  |> List.find_map (fun (sequence, params) ->
      if sequence > after && diagnostic_uri params = Some uri then Some params
      else None)

let readable_until descriptor deadline =
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0. then false
    else
      match Unix.select [ descriptor ] [] [] remaining with
      | [], _, _ -> false
      | _ -> true
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let wait_document_diagnostics session ~after ~uri =
  let deadline = Unix.gettimeofday () +. timeout_seconds in
  let persistent_diagnostics = ref None in
  let rec receive_next ~after =
    if readable_until session.process.input deadline then (
      ignore (receive session deadline);
      loop ~after)
    else
      match !persistent_diagnostics with
      | Some diagnostics ->
          failf
            "ocamllsp kept persistent diagnostics for the acceptance buffer: %s"
            (pretty_to_string diagnostics)
      | None -> failf "timed out waiting for ocamllsp document diagnostics"
  and loop ~after =
    match diagnostics_after session ~after ~uri with
    | Some params -> (
        assert_no_auto_marker ~context:"ocamllsp diagnostics" params;
        match assoc_field "diagnostics" params with
        | Some (`List []) -> ()
        | Some diagnostics ->
            persistent_diagnostics := Some diagnostics;
            let after = session.diagnostic_sequence in
            receive_next ~after
        | None -> failf "ocamllsp diagnostics omitted the diagnostics list")
    | None -> receive_next ~after
  in
  loop ~after

let hover_params ~uri ~line =
  `Assoc
    [
      ("textDocument", `Assoc [ ("uri", `String uri) ]);
      ("position", `Assoc [ ("line", `Int line); ("character", `Int 5) ]);
    ]

let assert_hover ~context ~expected ~absent result =
  assert_no_auto_marker ~context result;
  let text = json_strings result |> String.concat "\n" in
  if not (contains ~needle:expected text) then
    failf "%s omitted residual leaf %s:\n%s" context expected text;
  if contains ~needle:absent text then
    failf "%s retained handled leaf %s:\n%s" context absent text

let initialize_params ~root_uri =
  `Assoc
    [
      ("processId", `Int (Unix.getpid ()));
      ("rootUri", `String root_uri);
      ( "workspaceFolders",
        `List
          [ `Assoc [ ("uri", `String root_uri); ("name", `String "hamlet") ] ]
      );
      ( "capabilities",
        `Assoc
          [
            ( "general",
              `Assoc
                [
                  ( "positionEncodings",
                    `List [ `String "utf-8"; `String "utf-16" ] );
                ] );
            ( "textDocument",
              `Assoc
                [
                  ( "hover",
                    `Assoc
                      [
                        ( "contentFormat",
                          `List [ `String "plaintext"; `String "markdown" ] );
                      ] );
                  ( "publishDiagnostics",
                    `Assoc [ ("versionSupport", `Bool false) ] );
                ] );
          ] );
    ]

let did_open_params ~uri ~text =
  `Assoc
    [
      ( "textDocument",
        `Assoc
          [
            ("uri", `String uri);
            ("languageId", `String "ocaml");
            ("version", `Int 1);
            ("text", `String text);
          ] );
    ]

let did_change_params ~uri ~text =
  `Assoc
    [
      ("textDocument", `Assoc [ ("uri", `String uri); ("version", `Int 2) ]);
      ("contentChanges", `List [ `Assoc [ ("text", `String text) ] ]);
    ]

let run root source binding =
  let root = Unix.realpath root in
  let source = Unix.realpath source in
  let root_uri = uri_of_path root in
  let uri = uri_of_path source in
  let saved = read_file source in
  let saved_pattern = "#Automatic_propagation_external.Storage.Errors.storage_missing" in
  let unsaved_pattern = "#Automatic_propagation_external.Storage.Errors.storage_timeout" in
  let unsaved, replacements =
    replace_all ~pattern:saved_pattern ~replacement:unsaved_pattern saved
  in
  if replacements = 0 then failf "the saved handler arm was not found";
  let line = line_of_binding ~binding saved in
  let process = launch_server () in
  let session = { process; diagnostic_sequence = 0; diagnostics = [] } in
  Fun.protect
    ~finally:(fun () -> terminate process)
    (fun () ->
      send_packet process
        (request ~id:1 ~method_:"initialize" (initialize_params ~root_uri));
      ignore (wait_response session 1);
      send_packet process (notification ~method_:"initialized" (`Assoc []));
      let diagnostics_before_open = session.diagnostic_sequence in
      send_packet process
        (notification ~method_:"textDocument/didOpen"
           (did_open_params ~uri ~text:saved));
      wait_document_diagnostics session ~after:diagnostics_before_open ~uri;
      send_packet process
        (request ~id:2 ~method_:"textDocument/hover" (hover_params ~uri ~line));
      let saved_hover = wait_response session 2 in
      assert_hover ~context:"saved hover" ~expected:"storage_timeout"
        ~absent:"storage_missing" saved_hover;
      print_endline "saved hover residual: storage_timeout";
      let diagnostics_before_change = session.diagnostic_sequence in
      send_packet process
        (notification ~method_:"textDocument/didChange"
           (did_change_params ~uri ~text:unsaved));
      wait_document_diagnostics session ~after:diagnostics_before_change ~uri;
      send_packet process
        (request ~id:3 ~method_:"textDocument/hover" (hover_params ~uri ~line));
      let unsaved_hover = wait_response session 3 in
      assert_hover ~context:"unsaved hover" ~expected:"storage_missing"
        ~absent:"storage_timeout" unsaved_hover;
      print_endline "unsaved hover residual: storage_missing";
      send_packet process (request_without_params ~id:4 ~method_:"shutdown");
      ignore (wait_response session 4);
      send_packet process (notification_without_params ~method_:"exit");
      close_output process;
      match waitpid_until process.pid (Unix.gettimeofday () +. 5.) with
      | Some (Unix.WEXITED 0) -> print_endline "ocamllsp shutdown: clean"
      | Some status ->
          failf "ocamllsp exited abnormally: %s"
            (match status with
            | Unix.WEXITED code -> Printf.sprintf "exit %d" code
            | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
            | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal)
      | None -> failf "ocamllsp did not exit after shutdown")

let () =
  Printexc.register_printer (function
    | Protocol_error message ->
        Some ("automatic propagation LSP test: " ^ message)
    | _ -> None);
  if Array.length Sys.argv <> 4 then
    invalid_arg "usage: automatic_propagation_lsp_client ROOT SOURCE BINDING";
  run Sys.argv.(1) Sys.argv.(2) Sys.argv.(3)
