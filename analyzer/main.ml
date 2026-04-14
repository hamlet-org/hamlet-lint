(** [hamlet-lint] entry point. Reads ND-JSON records from stdin or a file, runs
    the rule, prints findings, sets the exit code.

    Exit codes:
    - 0 clean run, or findings present with [--warn-only]
    - 1 findings present (default)
    - 2 malformed input (missing header or unsupported schema version) *)

open Hamlet_lint_schema.Schema
module Rule = Hamlet_lint_analyzer.Rule
module Report = Hamlet_lint_analyzer.Report
module Config = Hamlet_lint_config.Config

(** If a config file is discoverable at or above cwd, read it and return whether
    its [mode] field is [warn]. Any error reading the file (missing, parse
    error, unknown key) is swallowed and treated as "no config": the config is
    meant to reduce typing, not to be a hard requirement. *)
let warn_mode_from_config () =
  match Config.find () with
  | None -> false
  | Some path -> (
      match Config.load path with
      | Ok cfg -> cfg.mode = Config.Warn
      | Error _ -> false)

let run input cli_warn_only =
  let warn_only = cli_warn_only || warn_mode_from_config () in
  let ic = match input with None -> stdin | Some p -> open_in p in
  let records = read_ndjson ic in
  (match input with Some _ -> close_in ic | None -> ());
  (* Schema guard: reject any stream whose first record isn't a header with
     the current major version. The analyzer exits 2 (malformed input) so
     callers can distinguish "bug" from "findings present". *)
  (match records with
  | Header h :: _ when h.schema_version = schema_version -> ()
  | Header h :: _ ->
      Printf.eprintf
        "hamlet-lint: unsupported schema_version %d (this binary speaks %d)\n"
        h.schema_version schema_version;
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
    "Semantic linter for stale forwarding arms in Hamlet row handlers."
  in
  let info = Cmd.info "hamlet-lint" ~doc in
  Cmd.v info Term.(const run $ input $ warn_only)

let () = exit (Cmd.eval' cmd)
