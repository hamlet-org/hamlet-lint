(** Project-level configuration for hamlet-lint.

    The file is an s-expression with a small fixed schema. Its purpose is to let
    a project declare "run the linter on these paths, with these flags" once, so
    developers can invoke [hamlet-lint] with no arguments and get consistent
    results locally and in CI.

    Expected file name: [.hamlet-lint.sexp] at the project root (the directory
    containing [dune-project], which is discovered by walking up from the
    current working directory).

    Example:

    {v
    (targets
      _build/default/lib
      _build/default/bin)
    (exclude
      _build/default/test)
    (mode warn)
    v}

    - [targets]: list of paths to walk for .cmt files. Required. At least one
      entry.
    - [exclude]: list of paths to skip. Optional, defaults to empty.
    - [mode]: [fail] (findings exit 1, default) or [warn] (always exit 0).

    Every field except [targets] is optional. Unknown top-level forms are a
    parse error so typos are caught loudly instead of silently ignored. *)

type mode = Fail | Warn

type t = {
  targets : string list;
  exclude : string list;
  mode : mode;
  source_path : string;
      (** absolute path of the config file this record was parsed from, kept for
          diagnostics and for resolving the [targets] entries (which may be
          relative to the config file's directory). *)
}

let default_filename = ".hamlet-lint.sexp"

(** Walk up from [start_dir] looking for [filename]. Return the absolute path of
    the first match, or [None] if the root is reached without finding it. *)
let find_upwards ?(filename = default_filename) start_dir =
  let rec go dir =
    let candidate = Filename.concat dir filename in
    if Sys.file_exists candidate then Some candidate
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else go parent
  in
  go (Unix.realpath start_dir)

(** Convenience: search from the current working directory. *)
let find () = find_upwards (Sys.getcwd ())

(* ------------------------------------------------------------------ *)
(* Sexp → [t]                                                         *)
(* ------------------------------------------------------------------ *)

module S = Sexplib0.Sexp

(** Extract a list of string atoms from the tail of a form. Accepts both
    [(key a b c)] and [(key (a b c))]; both are idiomatic. Rejects anything else
    with a [Failure] carrying the key name. *)
let expect_atoms key rest =
  (* Accept either [(key a b c)] or [(key (a b c))] — both are idiomatic
     s-expression shapes. Normalise the two forms, then map to strings. *)
  let atoms = match rest with [ S.List xs ] -> xs | xs -> xs in
  List.map
    (function
      | S.Atom s -> s
      | S.List _ ->
          failwith (Printf.sprintf "%s: expected atoms, got nested list" key))
    atoms

let expect_single_atom key = function
  | [ S.Atom s ] -> s
  | _ -> failwith (Printf.sprintf "%s: expected a single atom" key)

let parse_mode = function
  | "fail" -> Fail
  | "warn" -> Warn
  | other ->
      failwith (Printf.sprintf "mode: expected 'fail' or 'warn', got %S" other)

let parse_form ~source_path acc = function
  | S.List (S.Atom key :: rest) -> (
      match key with
      | "targets" -> { acc with targets = expect_atoms "targets" rest }
      | "exclude" -> { acc with exclude = expect_atoms "exclude" rest }
      | "mode" ->
          { acc with mode = parse_mode (expect_single_atom "mode" rest) }
      | other ->
          failwith
            (Printf.sprintf
               "%s: unknown top-level form %S (expected one of: targets, \
                exclude, mode)"
               source_path other))
  | S.List _ ->
      failwith
        (Printf.sprintf "%s: top-level form must start with a key atom"
           source_path)
  | S.Atom _ ->
      failwith
        (Printf.sprintf "%s: bare atom at top level, expected (key value...)"
           source_path)

let empty source_path = { targets = []; exclude = []; mode = Fail; source_path }

let validate cfg =
  if cfg.targets = [] then
    failwith
      (Printf.sprintf
         "%s: at least one 'targets' path is required — hamlet-lint would have \
          nothing to analyse"
         cfg.source_path);
  cfg

(** [load path] parses [path] as s-expression config and returns a {!t}, or an
    [Error msg] if the file does not parse or the schema is wrong. The caller is
    responsible for the "config file was found" decision — this function assumes
    the file exists. *)
let load path =
  try
    let content = In_channel.with_open_text path In_channel.input_all in
    match Parsexp.Many.parse_string content with
    | Error pe ->
        Error
          (Printf.sprintf "%s: parse error: %s" path
             (Parsexp.Parse_error.message pe))
    | Ok sexps ->
        let acc = empty (Unix.realpath path) in
        let cfg = List.fold_left (parse_form ~source_path:path) acc sexps in
        Ok (validate cfg)
  with
  | Failure msg -> Error msg
  | Sys_error msg -> Error (Printf.sprintf "%s: %s" path msg)

(** Resolve a relative path from the config against the config file's directory,
    so invoking [hamlet-lint] from a subdirectory still points at the right
    build outputs. *)
let resolve_path cfg p =
  if Filename.is_relative p then
    Filename.concat (Filename.dirname cfg.source_path) p
  else p

let resolved_targets cfg = List.map (resolve_path cfg) cfg.targets
let resolved_exclude cfg = List.map (resolve_path cfg) cfg.exclude
