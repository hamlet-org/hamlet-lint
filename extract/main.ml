(** [hamlet-lint-extract] — compiler-libs facing binary. Reads one or more
    [.cmt] files (or directories walked recursively) and emits ND-JSON to
    stdout, one record per line: first a header, then one [concrete_site] record
    per recognised §2.0 application.

    v0.1 scope: only [Hamlet.Combinators.provide], [Hamlet.Combinators.catch],
    [Hamlet.Combinators.map_error] with inline [function] handlers. Layer
    combinators, the PPX Tag.provide pass-through, and latent/cross-module
    wrapper resolution are explicit v0.1.1 TODOs. *)

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

(** Cache an [(modname, structure)] pair for a cmt file, so the fixed-point
    iteration in Phase 3 can re-scan structures without re-reading from disk. *)
type loaded_cmt = { modname : string; str : Typedtree.structure }

let load_cmts (files : string list) : loaded_cmt list =
  List.filter_map
    (fun file ->
      try
        let cmt = Cmt_format.read_cmt file in
        match cmt.cmt_annots with
        | Cmt_format.Implementation str ->
            Some { modname = cmt.cmt_modname; str }
        | _ -> None
      with e ->
        Printf.eprintf "hamlet-lint-extract: skipping %s (%s)\n" file
          (Printexc.to_string e);
        None)
    files

(** First pass: walk every already-loaded cmt structure and accumulate top-level
    function bindings into the global handler table used by
    [Walker.resolve_to_function] for cross-module [Pdot] resolution. Reusing the
    structures from [load_cmts] halves disk I/O vs re-reading every file, and
    drops the silent error branch (errors are already surfaced on load). *)
let build_global_env (cmts : loaded_cmt list) : Walker.global_env =
  let globals = Walker.empty_globals () in
  List.iter
    (fun lc ->
      Walker.collect_global_bindings ~modname:lc.modname lc.str globals)
    cmts;
  globals

(** Phase 2 (revised for v0.1.2): walk each loaded structure to emit concrete
    sites and the *initial* set of latent sites [S₀]. Call sites are NOT emitted
    in this phase — they are produced once in Phase 4 against the fixed-point
    closure. *)
let phase2_initial_walk ~(globals : Walker.global_env) (cmts : loaded_cmt list)
    : Walker.walk_result list =
  List.map
    (fun lc ->
      let r =
        Walker.walk_structure ~globals ~modname:lc.modname ~extra_latent_keys:[]
          lc.str
      in
      (* Drop any same-cmt call_sites the walker produced — we'll re-scan in
         Phase 4 with the global closure as the latent key set. *)
      { r with calls = [] })
    cmts

(** Phase 3 (v0.1.2 P3): monotonic fixed-point over latent sites. Each pass
    scans every loaded cmt for top-level functions whose body calls a known
    latent wrapper with a parameter-bound argument; such functions are promoted
    with the inner wrapper's row shape. Repeats until no new promotions in a
    full pass. Bounded by [|cmts|*hard_cap_factor + 10] to defend against a
    non-monotonic merge bug. *)
let phase3_fixed_point
    (cmts : loaded_cmt list)
    (initial : Hamlet_lint_schema.Schema.latent_site list) :
    Hamlet_lint_schema.Schema.latent_site list =
  let table = Walker.latent_table_of_list initial in
  (* Stable dedup of synthesized latents: a (key, kind, source loc) tuple
     identifies the upstream exemplar so that a function promoted via two
     distinct upstream wrappers gets two latent_site records (one per
     exemplar's row shape), and the analyzer joins each independently. *)
  let seen_synth : (string * string * int * int, unit) Hashtbl.t =
    Hashtbl.create 16
  in
  let result = ref initial in
  (* Paranoia ceiling. The real termination argument is [seen_synth]: it is
     append-only and keyed by [(function-path, kind, line, col)], so the
     iteration can run at most as many passes as there are distinct
     (function × exemplar-site) tuples in the load set — itself bounded by
     the AST node count. 1000 is comfortably above any realistic convergence
     depth (existing fixtures converge in 3–4) while still catching a
     non-monotonic regression loudly. *)
  let max_iters = 1000 in
  let iter = ref 0 in
  let changed = ref true in
  while !changed && !iter < max_iters do
    changed := false;
    incr iter;
    List.iter
      (fun lc ->
        let new_lats = Walker.promote_pass ~modname:lc.modname table lc.str in
        List.iter
          (fun (l : Hamlet_lint_schema.Schema.latent_site) ->
            let key =
              ( l.latent_in_function,
                Hamlet_lint_schema.Schema.combinator_kind_to_string l.kind,
                l.loc.line,
                l.loc.col )
            in
            if not (Hashtbl.mem seen_synth key) then begin
              Hashtbl.add seen_synth key ();
              (* Only first occurrence of a function as latent populates the
                 lookup table for further fixed-point chasing — additional
                 records for the same key still enter [result] for the
                 analyzer's join, but the lookup table only needs one
                 representative to drive promotion. *)
              if not (Hashtbl.mem table l.latent_in_function) then
                Hashtbl.add table l.latent_in_function l;
              result := l :: !result;
              changed := true
            end)
          new_lats)
      cmts
  done;
  if !changed then begin
    Printf.eprintf
      "hamlet-lint-extract: fixed-point iteration failed to converge after %d \
       passes; this is a walker bug (v0.1.2 P3), please file an issue with the \
       cmt paths involved\n"
      max_iters;
    exit 3
  end;
  !result

(** Phase 4 (v0.1.2 P1+P3): with the fixed-point closure of latent keys in hand,
    scan every cmt for [call_site] records that join against any latent function
    — local or cross-module, single-level or multi-level. *)
let phase4_call_sites
    (cmts : loaded_cmt list)
    (latents : Hamlet_lint_schema.Schema.latent_site list) :
    Hamlet_lint_schema.Schema.call_site list =
  let keys =
    List.sort_uniq compare
      (List.map
         (fun (l : Hamlet_lint_schema.Schema.latent_site) ->
           l.latent_in_function)
         latents)
  in
  if keys = [] then []
  else
    List.concat_map
      (fun lc ->
        let modpath = Compat.split_mangled lc.modname in
        Walker.scan_call_sites ~modpath lc.str keys)
      cmts

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
          (* Auto-discover only when the user has given us nothing. If
             they passed explicit inputs, don't second-guess them. *)
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
  let cmts = load_cmts cmts_files in
  let globals = build_global_env cmts in
  let initial = phase2_initial_walk ~globals cmts in
  let initial_concretes =
    List.concat_map (fun r -> r.Walker.concrete) initial
  in
  let initial_latents = List.concat_map (fun r -> r.Walker.latent) initial in
  let latents = phase3_fixed_point cmts initial_latents in
  let calls = phase4_call_sites cmts latents in
  let results : Walker.walk_result =
    { concrete = initial_concretes; latent = latents; calls }
  in
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
