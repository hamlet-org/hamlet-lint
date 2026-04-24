(** [hamlet-lint] entry point. Reads ND-JSON records from stdin or a file, runs
    the rule, prints findings, sets exit code.

    Exit codes:
    - 0 clean run, or findings present with [--warn-only] / config [warn]
    - 1 findings present (default)
    - 2 malformed input (missing header or unsupported schema version) *)

module S = Hamlet_lint_schema.Schema
module Rule = Hamlet_lint_analyzer.Rule
module Report = Hamlet_lint_analyzer.Report
module Config = Hamlet_lint_config.Config

let warn_mode_from_config () =
  match Config.find () with
  | None -> false
  | Some path -> (
      match Config.load path with
      | Ok cfg -> cfg.mode = Config.Warn
      | Error _ -> false)

(** Read ND-JSON from [ic] with deterministic error reporting. Any decoder
    failure (malformed JSON, missing fields, unknown record kind) is caught and
    turned into exit code 2 with a stderr line — never a stack trace. *)
let read_records_or_exit2 (ic : in_channel) : S.record list =
  try S.read_ndjson ic with
  | Yojson.Json_error msg ->
      Printf.eprintf "hamlet-lint: malformed ND-JSON: %s\n" msg;
      exit 2
  | Failure msg ->
      Printf.eprintf "hamlet-lint: malformed record: %s\n" msg;
      exit 2

(** Open the input channel for reading. Missing or unreadable files surface as
    exit 2 (user error) rather than the default uncaught [Sys_error] / exit 125.
*)
let open_input_or_exit2 = function
  | None -> stdin
  | Some p -> (
      try open_in p
      with Sys_error msg ->
        Printf.eprintf "hamlet-lint: %s\n" msg;
        exit 2)

let run input cli_warn_only =
  let warn_only = cli_warn_only || warn_mode_from_config () in
  let ic = open_input_or_exit2 input in
  let records = read_records_or_exit2 ic in
  (match input with Some _ -> close_in ic | None -> ());
  (* Schema guard: reject any stream whose first record isn't a header
     with the current major version. *)
  (match records with
  | S.Header h :: _ when h.schema_version = S.schema_version -> ()
  | S.Header h :: _ ->
      Printf.eprintf
        "hamlet-lint: unsupported schema_version %d (this binary speaks %d)\n"
        h.schema_version S.schema_version;
      exit 2
  | _ ->
      Printf.eprintf
        "hamlet-lint: missing header record (expected first line to be \
         {\"kind\":\"header\",...})\n";
      exit 2);
  let findings = Rule.analyze records in
  print_string (Report.pretty findings);
  if findings = [] then 0 else if warn_only then 0 else 1

open Cmdliner

let input =
  let doc = "ND-JSON input file (default: stdin)." in
  Arg.(value & opt (some string) None & info [ "i"; "input" ] ~docv:"FILE" ~doc)

let warn_only =
  let doc =
    "Print findings but always exit 0. Overrides whatever the config file's \
     mode says."
  in
  Arg.(value & flag & info [ "warn-only"; "w" ] ~doc)

let cmd =
  let doc =
    "Semantic linter for retroactive widening in Hamlet's catch/provide \
     handlers."
  in
  let info = Cmd.info "hamlet-lint" ~doc in
  Cmd.v info Term.(const run $ input $ warn_only)

let () = exit (Cmd.eval' cmd)
