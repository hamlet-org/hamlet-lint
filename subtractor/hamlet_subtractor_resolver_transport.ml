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

let default_limits =
  {
    request_bytes = 4 * 1024 * 1024;
    response_bytes = 16 * 1024 * 1024;
    stderr_bytes = 256 * 1024;
    timeout_seconds = 10.;
  }

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let executable path =
  try
    let stats = Unix.stat path in
    if stats.st_kind <> Unix.S_REG then false
    else (
      Unix.access path [ Unix.X_OK ];
      true)
  with _ -> false

let resolver_names =
  if Sys.win32 then
    [ "hamlet-subtractor-resolver.exe"; "hamlet-subtractor-resolver" ]
  else [ "hamlet-subtractor-resolver"; "hamlet_subtractor_resolver.exe" ]

let source_tree_candidates ~executable_name =
  let rec find_ppx_directory directory =
    if String.equal (Filename.basename directory) ".ppx" then Some directory
    else
      let parent = Filename.dirname directory in
      if String.equal parent directory then None else find_ppx_directory parent
  in
  executable_name
  |> absolute
  |> Filename.dirname
  |> find_ppx_directory
  |> Option.fold ~none:[] ~some:(fun ppx_directory ->
      let resolver_directory =
        Filename.concat (Filename.dirname ppx_directory) "subtractor"
      in
      List.map (Filename.concat resolver_directory) resolver_names)

let find_resolver () =
  let site_candidates =
    Hamlet_subtractor_sites.Sites.resolver
    |> List.concat_map (fun directory ->
        List.map (Filename.concat directory) resolver_names)
    |> List.map absolute
  in
  let candidates =
    site_candidates
    @ source_tree_candidates ~executable_name:Sys.executable_name
  in
  match List.find_opt executable candidates with
  | Some resolver -> Ok resolver
  | None -> Error (Resolver_not_found candidates)

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let kill_noerr pid =
  try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

let rec waitpid pid =
  try snd (Unix.waitpid [] pid)
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

let waitpid_noerr pid = try Some (waitpid pid) with Unix.Unix_error _ -> None

let poll_pid pid =
  try
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> None
    | _, status -> Some status
  with Unix.Unix_error (Unix.EINTR, _, _) -> None

let is_retry = function
  | Unix.EINTR | Unix.EAGAIN | Unix.EWOULDBLOCK -> true
  | _ -> false

type channel = { descriptor : Unix.file_descr; buffer : Buffer.t; limit : int }

type child = {
  pid : int;
  mutable input : Unix.file_descr option;
  mutable output : channel option;
  mutable errors : channel option;
  mutable status : Unix.process_status option;
}

let close_child child =
  Option.iter close_noerr child.input;
  Option.iter (fun channel -> close_noerr channel.descriptor) child.output;
  Option.iter (fun channel -> close_noerr channel.descriptor) child.errors;
  child.input <- None;
  child.output <- None;
  child.errors <- None

let terminate child =
  close_child child;
  match child.status with
  | Some _ -> ()
  | None ->
      kill_noerr child.pid;
      child.status <- waitpid_noerr child.pid

let read_channel channel =
  let bytes = Bytes.create 65536 in
  let rec loop () =
    try
      match Unix.read channel.descriptor bytes 0 (Bytes.length bytes) with
      | 0 -> Ok `Eof
      | count ->
          Buffer.add_subbytes channel.buffer bytes 0 count;
          let actual = Buffer.length channel.buffer in
          if actual > channel.limit then Error (`Too_large actual) else loop ()
    with
    | Unix.Unix_error (error, _, _) when is_retry error -> Ok `Open
    | exn -> Error (`Io (Printexc.to_string exn))
  in
  loop ()

let write_input descriptor payload offset =
  try
    let count =
      Unix.write_substring descriptor payload offset
        (String.length payload - offset)
    in
    Ok (offset + count)
  with
  | Unix.Unix_error (Unix.EPIPE, _, _) -> Error Input_closed
  | Unix.Unix_error (error, _, _) when is_retry error -> Ok offset
  | exn -> Error (Io_failed (Printexc.to_string exn))

(* The package-private runtime calls this only from a one-shot, single-threaded
   Ppxlib driver. The scoped process signal change therefore has no concurrent
   observer, and the previous disposition is restored after child cleanup. *)
let with_sigpipe_ignored f =
  let previous = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous) f

let status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal

let spawn ~program ~arguments ~response_limit ~stderr_limit =
  let descriptors = ref [] in
  let spawned = ref None in
  try
    let pipe () =
      let first, second = Unix.pipe ~cloexec:true () in
      descriptors := first :: second :: !descriptors;
      (first, second)
    in
    let child_input, parent_input = pipe () in
    let parent_output, child_output = pipe () in
    let parent_errors, child_errors = pipe () in
    let argv = Array.append [| program |] arguments in
    let pid =
      Unix.create_process_env program argv (Unix.environment ()) child_input
        child_output child_errors
    in
    spawned := Some pid;
    close_noerr child_input;
    close_noerr child_output;
    close_noerr child_errors;
    Unix.set_nonblock parent_input;
    Unix.set_nonblock parent_output;
    Unix.set_nonblock parent_errors;
    Ok
      {
        pid;
        input = Some parent_input;
        output =
          Some
            {
              descriptor = parent_output;
              buffer = Buffer.create 4096;
              limit = response_limit + 9;
            };
        errors =
          Some
            {
              descriptor = parent_errors;
              buffer = Buffer.create 256;
              limit = stderr_limit;
            };
        status = None;
      }
  with exn ->
    List.iter close_noerr !descriptors;
    Option.iter
      (fun pid ->
        kill_noerr pid;
        waitpid_noerr pid |> ignore)
      !spawned;
    Error (Spawn_failed (Printexc.to_string exn))

let collect ?(limits = default_limits) ~program ~arguments payload =
  let actual = String.length payload in
  if actual > limits.request_bytes then
    Error (Request_too_large { limit = limits.request_bytes; actual })
  else
    match
      try Ok (Hamlet_subtractor_monotonic.now ())
      with exn -> Error (Io_failed (Printexc.to_string exn))
    with
    | Error _ as error -> error
    | Ok started -> (
        match
          spawn ~program ~arguments ~response_limit:limits.response_bytes
            ~stderr_limit:limits.stderr_bytes
        with
        | Error _ as error -> error
        | Ok child ->
            let offset = ref 0 in
            let failure = ref None in
            let close_input () =
              Option.iter close_noerr child.input;
              child.input <- None
            in
            let close_output () = function
              | `Stdout ->
                  Option.iter
                    (fun channel -> close_noerr channel.descriptor)
                    child.output;
                  child.output <- None
              | `Stderr ->
                  Option.iter
                    (fun channel -> close_noerr channel.descriptor)
                    child.errors;
                  child.errors <- None
            in
            let output_buffer =
              match child.output with
              | Some channel -> channel.buffer
              | None -> assert false
            in
            let error_buffer =
              match child.errors with
              | Some channel -> channel.buffer
              | None -> assert false
            in
            let rec loop () =
              if Option.is_none child.status then
                child.status <- poll_pid child.pid;
              if Option.is_some !failure then ()
              else if
                Option.is_some child.status
                && Option.is_none child.input
                && Option.is_none child.output
                && Option.is_none child.errors
              then ()
              else
                let elapsed = Hamlet_subtractor_monotonic.now () -. started in
                if elapsed >= limits.timeout_seconds then
                  failure := Some (Timeout limits.timeout_seconds)
                else
                  let read_descriptors =
                    List.filter_map
                      (fun channel ->
                        Option.map (fun value -> value.descriptor) channel)
                      [ child.output; child.errors ]
                  in
                  let write_descriptors =
                    match child.input with
                    | Some descriptor when !offset < String.length payload ->
                        [ descriptor ]
                    | Some _ ->
                        close_input ();
                        []
                    | None -> []
                  in
                  let timeout = min 0.1 (limits.timeout_seconds -. elapsed) in
                  let readable, writable =
                    try
                      let readable, writable, _ =
                        Unix.select read_descriptors write_descriptors []
                          timeout
                      in
                      (readable, writable)
                    with
                    | Unix.Unix_error (Unix.EINTR, _, _) -> ([], [])
                    | exn ->
                        failure := Some (Io_failed (Printexc.to_string exn));
                        ([], [])
                  in
                  begin match child.input with
                  | Some descriptor when List.mem descriptor writable -> (
                      match write_input descriptor payload !offset with
                      | Ok next ->
                          offset := next;
                          if next = String.length payload then close_input ()
                      | Error error -> failure := Some error)
                  | Some _ | None -> ()
                  end;
                  let read kind channel =
                    if List.mem channel.descriptor readable then
                      match read_channel channel with
                      | Ok `Open -> ()
                      | Ok `Eof -> close_output () kind
                      | Error (`Io detail) -> failure := Some (Io_failed detail)
                      | Error (`Too_large actual) ->
                          failure :=
                            Some
                              (match kind with
                              | `Stdout ->
                                  Response_too_large
                                    { limit = limits.response_bytes; actual }
                              | `Stderr ->
                                  Stderr_too_large
                                    { limit = limits.stderr_bytes; actual })
                  in
                  Option.iter (read `Stdout) child.output;
                  Option.iter (read `Stderr) child.errors;
                  loop ()
            in
            Fun.protect
              ~finally:(fun () ->
                if Option.is_none child.status then terminate child
                else close_child child)
              (fun () ->
                try
                  loop ();
                  match !failure with
                  | Some error -> Error error
                  | None ->
                      let status = Option.get child.status in
                      let stderr = Buffer.contents error_buffer in
                      begin match status with
                      | Unix.WEXITED 0 when stderr = "" ->
                          Ok (Buffer.contents output_buffer)
                      | Unix.WEXITED 0 -> Error (Unexpected_stderr stderr)
                      | status -> Error (Process_failed (status, stderr))
                      end
                with exn -> Error (Io_failed (Printexc.to_string exn))))

let validate_remote_failure
    request
    (failure : Hamlet_subtractor_resolver_protocol.remote_failure) =
  let expected_request_id = Protocol.request_id request in
  if
    not
      (String.equal expected_request_id
         failure.Hamlet_subtractor_resolver_protocol.request_id)
  then
    Error
      (Protocol.Request_id_mismatch
         { expected = expected_request_id; actual = failure.request_id })
  else
    let expected_context = Protocol.request_context_fingerprint request in
    if not (String.equal expected_context failure.context_fingerprint) then
      Error
        (Protocol.Context_fingerprint_mismatch
           { expected = expected_context; actual = failure.context_fingerprint })
    else
      let expected_digest = (Protocol.probe_ast request).digest in
      if String.equal expected_digest failure.ast_digest then Ok ()
      else
        Error
          (Protocol.Ast_digest_mismatch
             { expected = expected_digest; actual = failure.ast_digest })

let run_program ?limits ~program ~arguments request =
  if Sys.win32 then Error (Unsupported_platform "Windows")
  else
    let request_payload = Protocol.encode_request request in
    let framed =
      Hamlet_subtractor_resolver_protocol.encode_frame request_payload
    in
    let collected =
      with_sigpipe_ignored (fun () ->
          collect ?limits ~program:(absolute program) ~arguments framed)
    in
    match collected with
    | Error _ as error -> error
    | Ok output -> (
        let maximum =
          match limits with
          | None -> default_limits.response_bytes
          | Some limits -> limits.response_bytes
        in
        match
          Hamlet_subtractor_resolver_protocol.decode_frame ~max_payload:maximum
            output
        with
        | Error error -> Error (Framing error)
        | Ok payload -> (
            match Hamlet_subtractor_resolver_protocol.decode_output payload with
            | Error error -> Error (Output_decode error)
            | Ok (Hamlet_subtractor_resolver_protocol.Typing_failure failure)
              -> (
                match validate_remote_failure request failure with
                | Ok () -> Error (Remote_typing_failure failure)
                | Error error -> Error (Correlation error))
            | Ok (Hamlet_subtractor_resolver_protocol.Response response) -> (
                match Protocol.validate_response ~request ~response with
                | Ok () -> Ok response
                | Error error -> Error (Correlation error))))

let run ?limits request =
  match find_resolver () with
  | Error _ as error -> error
  | Ok program -> run_program ?limits ~program ~arguments:[||] request

let message = function
  | Resolver_not_found candidates ->
      "lockstep resolver executable was not found in the Hamlet Dune site: "
      ^ String.concat ", " candidates
  | Unsupported_platform platform ->
      "the isolated resolver transport is not supported on " ^ platform
  | Request_too_large { limit; actual } ->
      Printf.sprintf "resolver request is too large: %d bytes exceeds %d" actual
        limit
  | Response_too_large { limit; actual } ->
      Printf.sprintf "resolver response is too large: %d bytes exceeds %d"
        actual limit
  | Stderr_too_large { limit; actual } ->
      Printf.sprintf "resolver stderr is too large: %d bytes exceeds %d" actual
        limit
  | Spawn_failed detail -> "could not start the resolver: " ^ detail
  | Io_failed detail -> "resolver transport I/O failed: " ^ detail
  | Timeout seconds ->
      Printf.sprintf "resolver exceeded its %.3g second timeout" seconds
  | Input_closed -> "resolver closed its request pipe before reading the frame"
  | Process_failed (status, stderr) ->
      let suffix = if stderr = "" then "" else ": " ^ String.trim stderr in
      "resolver process failed with " ^ status_to_string status ^ suffix
  | Unexpected_stderr stderr ->
      "resolver wrote unexpected stderr: " ^ String.trim stderr
  | Framing error ->
      Hamlet_subtractor_resolver_protocol.message
        (Hamlet_subtractor_resolver_protocol.Framing error)
  | Output_decode error ->
      Hamlet_subtractor_resolver_protocol.output_decode_error_message error
  | Remote_typing_failure failure -> failure.message
  | Correlation (Protocol.Request_id_mismatch _) ->
      "resolver response request identity does not match"
  | Correlation (Protocol.Context_fingerprint_mismatch _) ->
      "resolver response compilation context does not match"
  | Correlation (Protocol.Ast_digest_mismatch _) ->
      "resolver response binary AST digest does not match"
  | Correlation (Protocol.Missing_marker_result id) ->
      "resolver omitted marker " ^ Marker.id_to_string id
  | Correlation (Protocol.Unexpected_marker_result id) ->
      "resolver returned unknown marker " ^ Marker.id_to_string id
  | Correlation (Protocol.Marker_mismatch { expected; _ }) ->
      "resolver changed marker metadata for "
      ^ Marker.id_to_string (Marker.id expected)
