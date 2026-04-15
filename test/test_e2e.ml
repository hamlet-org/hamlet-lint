(** End-to-end pipeline tests: compiled fixture .cmt -> extractor -> analyzer.
    Invokes the two binaries via [Sys.command]. Depends on
    [dune build hamlet-lint hamlet-lint-extract] having produced them; the dune
    rule in [test/dune] pulls them in as dependencies.

    The cmt paths are hard-coded relative to [PROJECT_ROOT], which we discover
    by walking up from [Sys.getcwd ()] looking for the root [dune-project] file.

    Test bodies are table-driven: every row in [e2e_cases] specifies the fixture
    name, how to resolve its subject on disk (single .cmt vs whole directory),
    the expected exit code, and a list of substrings that must (or must not)
    appear in the analyzer output / extractor ND-JSON. *)

let rec find_project_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then failwith "no dune-project found"
    else find_project_root parent

let capitalise s =
  if s = "" then s
  else
    String.make 1 (Char.uppercase_ascii s.[0])
    ^ String.sub s 1 (String.length s - 1)

let cmt_path ~case ~module_cap =
  Printf.sprintf
    "_build/default/test/cases/%s/.hamlet_lint_fixture_%s.objs/byte/hamlet_lint_fixture_%s__%s.cmt"
    case case case module_cap

let dir_path ~case = Printf.sprintf "_build/default/test/cases/%s" case

let contains out sub =
  let len_s = String.length out and len_sub = String.length sub in
  let rec loop i =
    if i + len_sub > len_s then false
    else if String.sub out i len_sub = sub then true
    else loop (i + 1)
  in
  loop 0

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(** Subject on disk: either a single module's .cmt, or a whole fixture dir
    (needed when the extractor's three-phase build must see multiple cmts). *)
type subject = Cmt of { case : string; module_cap : string } | Dir of string

let subject_path ~root = function
  | Cmt { case; module_cap } ->
      Filename.concat root (cmt_path ~case ~module_cap)
  | Dir case -> Filename.concat root (dir_path ~case)

(** Run the full extract|analyze pipeline on a subject. If [env] is given it is
    prepended to the command (e.g. ["HAMLET_LINT_DEBUG=1"]). When
    [capture_stderr] is true (default), extractor stderr is folded into the
    output; when false, extractor stderr is captured separately and returned in
    place of stdout (used by the debug-diagnostic test). *)
let run ?(env = "") ?(capture_stderr = true) subject =
  let root = find_project_root (Sys.getcwd ()) in
  let path = subject_path ~root subject in
  if not (Sys.file_exists path) then `Skipped
  else
    let out_file = Filename.temp_file "hamlet-lint-e2e" ".txt" in
    let env_prefix = if env = "" then "" else env ^ " " in
    let cmd =
      if capture_stderr then
        Printf.sprintf
          "%shamlet-lint-extract --canonical %s 2>/dev/null | hamlet-lint > %s \
           2>&1"
          env_prefix (Filename.quote path) (Filename.quote out_file)
      else
        Printf.sprintf
          "%shamlet-lint-extract --canonical %s 2>%s | hamlet-lint >/dev/null"
          env_prefix (Filename.quote path) (Filename.quote out_file)
    in
    let code = Sys.command cmd in
    let s = read_file out_file in
    Sys.remove out_file;
    `Ran (code, s)

(** Run just the extractor (no analyzer) to capture the canonical ND-JSON. *)
let extract_raw subject =
  let root = find_project_root (Sys.getcwd ()) in
  let path = subject_path ~root subject in
  if not (Sys.file_exists path) then None
  else
    let out_file = Filename.temp_file "hamlet-lint-extract" ".txt" in
    let cmd =
      Printf.sprintf "hamlet-lint-extract --canonical %s >%s 2>/dev/null"
        (Filename.quote path) (Filename.quote out_file)
    in
    let _ = Sys.command cmd in
    let s = read_file out_file in
    Sys.remove out_file;
    Some s

(* ---------------------------------------------------------------- *)
(*  Expectation record + table                                      *)
(* ---------------------------------------------------------------- *)

type expect = {
  exit_code : int;
  out_contains : string list;
  out_absent : string list;
  ndjson_contains : string list;
}

let ok_clean =
  {
    exit_code = 0;
    out_contains = [ "no findings" ];
    out_absent = [];
    ndjson_contains = [];
  }

let stale ?(extra = []) tags =
  {
    exit_code = 1;
    out_contains = List.map (fun t -> "tag `" ^ t) tags @ extra;
    out_absent = [];
    ndjson_contains = [];
  }

let body_introduces ?(extra_contains = []) tag =
  {
    exit_code = 0;
    out_contains = "no findings" :: extra_contains;
    out_absent = [];
    ndjson_contains = [ "\"body_introduces\":[\"" ^ tag ^ "\"]" ];
  }

(** Build the default Cmt subject from a fixture name (capitalised module). *)
let cmt_of case = Cmt { case; module_cap = capitalise case }

(** A test case: group label, display name (used as Alcotest.test_case name,
    defaulting to the fixture dir so failures are one-click navigable), the
    subject to run, and the expectation. *)
type case = {
  group : string;
  name : string;
  subject : subject;
  expect : expect;
}

let mk ?name ~group ?subject case expect =
  let subject = match subject with Some s -> s | None -> cmt_of case in
  let name = match name with Some n -> n | None -> case in
  { group; name; subject; expect }

let e2e_cases : case list =
  [
    (* inline_stale *)
    mk ~group:"inline" "inline_stale" (stale [ "Forbidden"; "Timeout" ]);
    (* aliased_provide_stale *)
    mk ~group:"aliased_provide" "aliased_provide_stale" (stale [ "Logger" ]);
    (* layer *)
    mk ~group:"layer" "layer_provide_stale"
      (stale ~extra:[ "Hamlet.Layer.provide" ] [ "Logger" ]);
    mk ~group:"layer" "layer_provide_layer_stale"
      (stale ~extra:[ "Hamlet.Layer.provide_layer" ] [ "Logger" ]);
    mk ~group:"layer" "layer_provide_all_stale"
      (stale ~extra:[ "Hamlet.Layer.provide_all" ] [ "Logger" ]);
    mk ~group:"layer" "layer_catch_stale"
      (stale ~extra:[ "Hamlet.Layer.catch" ] [ "Forbidden"; "Timeout" ]);
    (* tag_provide (clean by construction) *)
    mk ~group:"tag_provide" "tag_provide_clean" ok_clean;
    (* latent wrappers *)
    mk ~group:"latent" "wrapper_stale" (stale [ "Logger" ]);
    mk ~group:"latent" "wrapper_clean" ok_clean;
    mk ~group:"latent" "wrapper_no_callers_clean" ok_clean;
    (* ident_handler *)
    mk ~group:"ident_handler" "let_bound_handler_stale" (stale [ "Logger" ]);
    mk ~group:"ident_handler" "aliased_handler_stale" (stale [ "Logger" ]);
    mk ~group:"ident_handler" "nested_let_handler_stale" (stale [ "Logger" ]);
    mk ~group:"ident_handler" "cross_module_handler_stale"
      ~subject:(Dir "cross_module_handler_stale")
      {
        exit_code = 1;
        out_contains = [ "cross_module_handler.ml"; "tag `Logger" ];
        out_absent = [];
        ndjson_contains = [];
      };
    mk ~group:"ident_handler" "unresolvable_handler_clean" ok_clean;
    (* body_introducers (v0.1.1 set) *)
    mk ~group:"body_introducers" "errors_body_introducer_direct_clean"
      (body_introduces "Bar");
    mk ~group:"body_introducers" "errors_body_introducer_try_catch_clean"
      (body_introduces "Bar");
    mk ~group:"body_introducers" "errors_body_introducer_ppx_clean"
      (body_introduces "Foo_error");
    mk ~group:"body_introducers" "errors_multiple_arms_distinct_clean"
      (body_introduces "Quux");
    (* wrapper_cross_module (v0.1.2 P1) *)
    mk ~group:"wrapper_cross_module (v0.1.2 P1)" "wrapper_cross_module_stale"
      ~subject:(Dir "wrapper_cross_module_stale")
      {
        exit_code = 1;
        out_contains = [ "wrapper_b.ml"; "tag `Logger"; "wrapper_a.ml" ];
        out_absent = [];
        ndjson_contains = [];
      };
    mk ~group:"wrapper_cross_module (v0.1.2 P1)"
      "wrapper_cross_module_namespace_collision_stale"
      ~subject:(Dir "wrapper_cross_module_namespace_collision_stale")
      {
        exit_code = 1;
        out_contains = [ "tag `Logger"; "stale_mod.ml" ];
        out_absent = [ "clean_mod.ml" ];
        ndjson_contains = [];
      };
    (* transitive_introducers (v0.1.2 P2) *)
    mk ~group:"transitive_introducers (v0.1.2 P2)"
      "errors_body_introducer_local_helper_clean" (body_introduces "Bar");
    mk ~group:"transitive_introducers (v0.1.2 P2)"
      "errors_body_introducer_module_helper_clean" (body_introduces "Bar");
    mk ~group:"transitive_introducers (v0.1.2 P2)"
      "errors_body_introducer_cross_module_helper_clean"
      ~subject:(Dir "errors_body_introducer_cross_module_helper_clean") ok_clean;
    mk ~group:"transitive_introducers (v0.1.2 P2)"
      "errors_body_introducer_deep_chain_clean" (body_introduces "Bar");
    mk ~group:"transitive_introducers (v0.1.2 P2)"
      "errors_body_introducer_runaway_clean"
      {
        exit_code = 0;
        out_contains = [];
        out_absent = [];
        ndjson_contains = [ "\"body_introduces\":[]" ];
      };
    (* wrapper_multi_level (v0.1.2 P3) *)
    mk ~group:"wrapper_multi_level (v0.1.2 P3)" "wrapper_two_level_stale"
      (stale [ "Logger" ]);
    mk ~group:"wrapper_multi_level (v0.1.2 P3)" "wrapper_three_level_stale"
      (stale [ "Logger" ]);
    mk ~group:"wrapper_multi_level (v0.1.2 P3)" "wrapper_mutual_recursion_stale"
      (stale [ "Logger" ]);
    mk ~group:"wrapper_multi_level (v0.1.2 P3)" "wrapper_two_level_clean"
      ok_clean;
    mk ~group:"wrapper_multi_level (v0.1.2 P3)" "wrapper_two_level_mixed_stale"
      (stale [ "Logger" ]);
  ]

let check_case case () =
  match run case.subject with
  | `Skipped -> Alcotest.skip ()
  | `Ran (code, out) -> (
      Alcotest.(check int) (case.name ^ " exit") case.expect.exit_code code;
      List.iter
        (fun s ->
          Alcotest.(check bool)
            (case.name ^ " contains " ^ s)
            true (contains out s))
        case.expect.out_contains;
      List.iter
        (fun s ->
          Alcotest.(check bool)
            (case.name ^ " absent " ^ s)
            false (contains out s))
        case.expect.out_absent;
      if case.expect.ndjson_contains <> [] then
        match extract_raw case.subject with
        | None -> Alcotest.fail "ndjson unavailable"
        | Some nd ->
            List.iter
              (fun s ->
                Alcotest.(check bool)
                  (case.name ^ " ndjson " ^ s)
                  true (contains nd s))
              case.expect.ndjson_contains)

(* ---------------------------------------------------------------- *)
(*  Special case: unresolvable_handler_debug reads extractor stderr *)
(*  directly. Kept as a single bespoke test below to avoid bloating *)
(*  the expect record with a capture_stderr toggle used exactly     *)
(*  once.                                                           *)
(* ---------------------------------------------------------------- *)

let test_unresolvable_handler_debug () =
  match
    run ~env:"HAMLET_LINT_DEBUG=1" ~capture_stderr:false
      (cmt_of "unresolvable_handler_clean")
  with
  | `Skipped -> Alcotest.skip ()
  | `Ran (_code, stderr_out) ->
      Alcotest.(check bool)
        "debug diagnostic emitted on stderr" true
        (contains stderr_out "skipping non-inline handler")

(* ---------------------------------------------------------------- *)
(*  Dispatcher                                                      *)
(* ---------------------------------------------------------------- *)

let () =
  (* Preserve group ordering as they first appear in [e2e_cases]; bucket
     cases into their group and emit one Alcotest group per bucket. *)
  let groups = ref [] in
  List.iter
    (fun c ->
      match List.assoc_opt c.group !groups with
      | Some _ ->
          groups :=
            List.map
              (fun (g, lst) ->
                if g = c.group then (g, lst @ [ c ]) else (g, lst))
              !groups
      | None -> groups := !groups @ [ (c.group, [ c ]) ])
    e2e_cases;
  let debug_case =
    Alcotest.test_case "unresolvable_handler_debug" `Quick
      test_unresolvable_handler_debug
  in
  let alcotest_groups =
    List.map
      (fun (group, cases) ->
        let tests =
          List.map
            (fun c -> Alcotest.test_case c.name `Quick (check_case c))
            cases
        in
        let tests =
          if group = "ident_handler" then tests @ [ debug_case ] else tests
        in
        (group, tests))
      !groups
  in
  Alcotest.run "hamlet-lint-e2e" alcotest_groups
