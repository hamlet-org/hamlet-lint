(** [hamlet-lint-extract] driver.

    Thin CLI: parses arguments and config, resolves the cmt file list, hands it
    to {!Pipeline.run}, then prints the ND-JSON records the pipeline returns.
    All walker and extractor logic lives in the sibling modules (see
    [docs/ARCHITECTURE.md] §2 for the phase map). *)

open Hamlet_lint_schema.Schema
module Config = Hamlet_lint_config.Config

(* A file ending in [.cmti] does not satisfy [check_suffix ".cmt"] because the
   tail compares as "cmti" vs "cmt" (different lengths), so no extra guard
   is needed. *)
let is_cmt f = Filename.check_suffix f ".cmt"

let rec collect_cmts path acc =
  if Sys.is_directory path then
    let entries = Sys.readdir path in
    Array.fold_left
      (fun acc name -> collect_cmts (Filename.concat path name) acc)
      acc entries
  else if is_cmt path then path :: acc
  else acc

let cmp_loc (a : loc) (b : loc) =
  let c = compare a.file b.file in
  if c <> 0 then c
  else
    let c = compare a.line b.line in
    if c <> 0 then c else compare a.col b.col

(** Canonicalise a walk result for snapshot tests: sort every kind of record by
    (file, line, col). *)
let canonicalise (r : Walker.walk_result) : Walker.walk_result =
  {
    concrete =
      List.sort
        (fun (a : concrete_site) (b : concrete_site) -> cmp_loc a.loc b.loc)
        r.concrete;
    latent =
      List.sort
        (fun (a : latent_site) (b : latent_site) -> cmp_loc a.loc b.loc)
        r.latent;
    calls =
      List.sort
        (fun (a : call_site) (b : call_site) -> cmp_loc a.loc b.loc)
        r.calls;
  }

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
  (* Merge explicit CLI inputs with config-file targets. Config supplies
     defaults; CLI positional args and --exclude are always applied on
     top. If neither CLI nor config gives us any target, we try
     auto-discovery: Config.find walks up from cwd looking for
     .hamlet-lint.sexp and uses that if present. *)
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
  let excludes = List.map Unix.realpath (!excludes @ cfg_excludes) in
  if inputs = [] then (
    prerr_endline
      "hamlet-lint-extract: no inputs given (pass a directory or create a \
       .hamlet-lint.sexp config)";
    exit 2);
  let cmts_files = List.fold_left (fun acc p -> collect_cmts p acc) [] inputs in
  let is_excluded f =
    let abs = try Unix.realpath f with Unix.Unix_error _ -> f in
    List.exists
      (fun prefix ->
        String.length abs >= String.length prefix
        && String.sub abs 0 (String.length prefix) = prefix)
      excludes
  in
  let cmts_files = List.filter (fun f -> not (is_excluded f)) cmts_files in
  let results = Pipeline.run cmts_files in
  let results = if !canonical then canonicalise results else results in
  let header =
    Header
      {
        schema_version;
        ocaml_version = Sys.ocaml_version;
        generated_at = (if !canonical then "canonical" else "runtime");
      }
  in
  print_endline (record_to_ndjson_line header);
  List.iter
    (fun s -> print_endline (record_to_ndjson_line (Concrete s)))
    results.concrete;
  List.iter
    (fun s -> print_endline (record_to_ndjson_line (Latent s)))
    results.latent;
  List.iter
    (fun c -> print_endline (record_to_ndjson_line (Call c)))
    results.calls
