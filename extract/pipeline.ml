(** Four-phase extractor pipeline.

    - Phase 1 [build_global_env]: walk every loaded cmt once to index top-level
      function bindings into a global handler table used by
      {!Handler_env.resolve_to_function} for cross-module [Pdot] resolution.
    - Phase 2 [initial_walk]: walk each structure to emit concrete sites and the
      initial set of latent sites S₀. Call sites are not emitted in this phase:
      they are produced once in Phase 4 against the fixed-point closure.
    - Phase 3 [fixed_point]: monotonic fixed-point over latent sites. Each pass
      scans every loaded cmt for top-level functions whose body calls a known
      latent wrapper with a parameter-bound argument; such functions are
      promoted with the inner wrapper's row shape. Repeats until a full pass
      produces no new promotions.
    - Phase 4 [call_sites]: with the fixed-point closure of latent keys in hand,
      scan every cmt for [call_site] records that join against any latent
      function, local or cross-module, single-level or multi-level. *)

open Hamlet_lint_schema.Schema

(** Cache an [(modname, structure)] pair for a cmt file, so the fixed-point
    iteration in phase 3 can re-scan structures without re-reading from disk. *)
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

let build_global_env (cmts : loaded_cmt list) : Handler_env.global_env =
  let globals = Handler_env.empty_globals () in
  List.iter
    (fun lc ->
      Walker.collect_global_bindings ~modname:lc.modname lc.str globals)
    cmts;
  globals

let initial_walk ~(globals : Handler_env.global_env) (cmts : loaded_cmt list) :
    Walker.walk_result list =
  List.map
    (fun lc ->
      let r =
        Walker.walk_structure ~globals ~modname:lc.modname ~extra_latent_keys:[]
          lc.str
      in
      (* Drop any same-cmt call_sites the walker produced: phase 4 re-scans
         with the global closure as the latent key set. *)
      { r with calls = [] })
    cmts

(** Paranoia ceiling for the fixed-point loop. The real termination argument is
    [seen_synth]: it is append-only and keyed by
    [(function-path, kind, line, col)], so the iteration can run at most as many
    passes as there are distinct (function × exemplar-site) tuples in the load
    set, itself bounded by the AST node count. 1000 is comfortably above any
    realistic convergence depth (existing fixtures converge in 3–4) while still
    catching a non-monotonic regression loudly. *)
let max_fixed_point_iters = 1000

let fixed_point (cmts : loaded_cmt list) (initial : latent_site list) :
    latent_site list =
  let table = Latent_fixpoint.table_of_list initial in
  (* Stable dedup of synthesized latents: a (key, kind, source loc) tuple
     identifies the upstream exemplar so that a function promoted via two
     distinct upstream wrappers gets two latent_site records (one per
     exemplar's row shape), and the analyzer joins each independently. *)
  let seen_synth : (string * string * int * int, unit) Hashtbl.t =
    Hashtbl.create 16
  in
  let result = ref initial in
  let iter = ref 0 in
  let changed = ref true in
  while !changed && !iter < max_fixed_point_iters do
    changed := false;
    incr iter;
    List.iter
      (fun lc ->
        let new_lats =
          Latent_fixpoint.promote_pass ~modname:lc.modname table lc.str
        in
        List.iter
          (fun (l : latent_site) ->
            let key =
              ( l.latent_in_function,
                combinator_kind_to_string l.kind,
                l.loc.line,
                l.loc.col )
            in
            if not (Hashtbl.mem seen_synth key) then begin
              Hashtbl.add seen_synth key ();
              (* Only first occurrence of a function as latent populates the
                 lookup table for further fixed-point chasing: additional
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
       passes; this is a walker bug, please file an issue with the cmt paths \
       involved\n"
      max_fixed_point_iters;
    exit 3
  end;
  !result

let call_sites (cmts : loaded_cmt list) (latents : latent_site list) :
    call_site list =
  let keys =
    List.sort_uniq compare
      (List.map (fun (l : latent_site) -> l.latent_in_function) latents)
  in
  if keys = [] then []
  else
    List.concat_map
      (fun lc ->
        let modpath = Compat.split_mangled lc.modname in
        Walker.scan_call_sites ~modpath lc.str keys)
      cmts

(** Run the full four-phase pipeline on a list of cmt files already resolved
    from the CLI and config. Returns a [walk_result] aggregated across the whole
    load set. *)
let run (cmts_files : string list) : Walker.walk_result =
  let cmts = load_cmts cmts_files in
  let globals = build_global_env cmts in
  let initial = initial_walk ~globals cmts in
  let concretes = List.concat_map (fun r -> r.Walker.concrete) initial in
  let initial_latents = List.concat_map (fun r -> r.Walker.latent) initial in
  let latents = fixed_point cmts initial_latents in
  let calls = call_sites cmts latents in
  { concrete = concretes; latent = latents; calls }
