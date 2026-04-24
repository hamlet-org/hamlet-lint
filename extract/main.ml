(** [hamlet-lint-extract] driver.

    Thin CLI: parses arguments and config, resolves the .cmt file list, walks
    them with {!Walker.walk_cmt}, and prints the ND-JSON records on stdout. All
    extraction logic lives in the sibling modules ({!Classify}, {!Handler},
    {!Upstream}, {!Tags}). *)

module S = Hamlet_lint_schema.Schema
module Config = Hamlet_lint_config.Config
module Walker = Hamlet_lint_extract.Walker

(** Print [msg] to stderr and exit 2 — the documented "user / input error" code.
    Used everywhere the extractor runs into a missing or unreadable filesystem
    path. *)
let die_user_error msg =
  Printf.eprintf "hamlet-lint-extract: %s\n" msg;
  exit 2

let is_cmt f = Filename.check_suffix f ".cmt"

let rec collect_cmts path acc =
  match Sys.is_directory path with
  | exception Sys_error msg -> die_user_error msg
  | true ->
      let entries =
        try Sys.readdir path with Sys_error msg -> die_user_error msg
      in
      Array.fold_left
        (fun acc name -> collect_cmts (Filename.concat path name) acc)
        acc entries
  | false -> if is_cmt path then path :: acc else acc

(** Resolve a user-supplied path or exit 2 with a clear message. Used for
    [--exclude] entries, where a typo on the command line should surface as a
    user error rather than an uncaught [Unix.Unix_error]. *)
let realpath_or_die p =
  try Unix.realpath p
  with Unix.Unix_error (err, _, _) ->
    die_user_error (Printf.sprintf "%s: %s" p (Unix.error_message err))

(** True iff [abs] equals [prefix] OR sits strictly under [prefix] as a path
    child. The [prefix + "/"] guard prevents [--exclude /a/foo] from also
    dropping [/a/foobar/...] (a real bug surfaced by codex review). *)
let is_under_prefix ~prefix ~abs =
  let p = prefix in
  let a = abs in
  if a = p then true
  else
    let pl = String.length p in
    String.length a > pl
    && String.sub a 0 pl = p
    && a.[pl] = Filename.dir_sep.[0]

let cmp_loc (a : S.loc) (b : S.loc) =
  let c = compare a.file b.file in
  if c <> 0 then c
  else
    let c = compare a.line b.line in
    if c <> 0 then c else compare a.col b.col

(** Stable order for snapshot tests: sort candidates by (file, line, col). *)
let canonicalise (cs : S.candidate list) : S.candidate list =
  List.sort (fun (a : S.candidate) b -> cmp_loc a.loc b.loc) cs

let () =
  let canonical = ref false in
  let inputs = ref [] in
  let excludes = ref [] in
  let config_path = ref None in
  let spec =
    [
      ( "--canonical",
        Arg.Set canonical,
        " Emit sorted output (stable for snapshot tests)" );
      ( "--exclude",
        Arg.String (fun p -> excludes := p :: !excludes),
        "PATH  Skip cmts whose absolute path starts with PATH. Repeatable." );
      ( "--config",
        Arg.String (fun p -> config_path := Some p),
        "FILE  Read targets/exclude from a project config (default: \
         auto-discover .hamlet-lint.sexp walking up from cwd)." );
    ]
  in
  Arg.parse spec
    (fun a -> inputs := a :: !inputs)
    "hamlet-lint-extract [--exclude PATH ...] [--config FILE] [FILES|DIRS]";
  let explicit_cli_inputs = List.rev !inputs in
  let cfg =
    match !config_path with
    | Some p -> (
        match Config.load p with
        | Ok c -> Some c
        | Error msg ->
            Printf.eprintf "hamlet-lint-extract: %s\n" msg;
            exit 2)
    | None ->
        if explicit_cli_inputs = [] then
          Option.bind (Config.find ()) (fun p ->
              match Config.load p with
              | Ok c -> Some c
              | Error msg ->
                  Printf.eprintf "hamlet-lint-extract: %s\n" msg;
                  exit 2)
        else None
  in
  let cfg_targets =
    match cfg with Some c -> Config.resolved_targets c | None -> []
  in
  let cfg_excludes =
    match cfg with Some c -> Config.resolved_exclude c | None -> []
  in
  let inputs = explicit_cli_inputs @ cfg_targets in
  let excludes = List.map realpath_or_die (!excludes @ cfg_excludes) in
  if inputs = [] then
    die_user_error
      "no inputs given (pass a directory or create a .hamlet-lint.sexp config)";
  let cmts_files = List.fold_left (fun acc p -> collect_cmts p acc) [] inputs in
  let is_excluded f =
    let abs = try Unix.realpath f with Unix.Unix_error _ -> f in
    List.exists (fun prefix -> is_under_prefix ~prefix ~abs) excludes
  in
  let cmts_files = List.filter (fun f -> not (is_excluded f)) cmts_files in
  let acc = ref [] in
  List.iter (fun p -> Walker.walk_cmt p acc) cmts_files;
  let candidates =
    let cs = List.rev !acc in
    if !canonical then canonicalise cs else cs
  in
  let header : S.record =
    Header
      {
        schema_version = S.schema_version;
        ocaml_version = Sys.ocaml_version;
        generated_at = (if !canonical then "canonical" else "runtime");
      }
  in
  print_endline (S.record_to_ndjson_line header);
  List.iter
    (fun c -> print_endline (S.record_to_ndjson_line (S.Candidate c)))
    candidates
