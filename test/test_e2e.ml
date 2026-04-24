(** End-to-end pipeline test: compile fixtures → extractor → analyzer → expected
    findings. Each fixture lists the lines where retroactive widening must be
    flagged; the test asserts that the analyzer's pretty output references
    exactly those lines and exits with the matching code. *)

(* ============================================================ *)
(* Project root + paths                                         *)
(* ============================================================ *)

let rec find_project_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then
      failwith "test_e2e: could not find dune-project walking up from cwd"
    else find_project_root parent

let project_root = find_project_root (Sys.getcwd ())
let build_dir = Filename.concat project_root "_build/default"
let extract_bin = Filename.concat build_dir "extract/main.exe"
let analyze_bin = Filename.concat build_dir "analyzer/main.exe"

let cmt_for fixture =
  Filename.concat build_dir
    (Printf.sprintf
       "test/cases/.hamlet_lint_fixtures.objs/byte/hamlet_lint_fixtures__%s.cmt"
       fixture)

(* ============================================================ *)
(* Run extract | analyze, capture stdout + exit                 *)
(* ============================================================ *)

let read_all ic =
  let buf = Buffer.create 1024 in
  try
    while true do
      Buffer.add_channel buf ic 4096
    done;
    assert false
  with End_of_file -> Buffer.contents buf

let run_pipeline (cmt : string) : string * int =
  let cmd =
    Printf.sprintf "%s %s | %s"
      (Filename.quote extract_bin)
      (Filename.quote cmt)
      (Filename.quote analyze_bin)
  in
  let ic = Unix.open_process_in cmd in
  let out = read_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with WEXITED n -> n | _ -> 255 in
  (out, code)

(* ============================================================ *)
(* Per-fixture expectations                                     *)
(* ============================================================ *)

(* Each entry: fixture base name, expected exit code (0 clean / 1 findings),
   list of lines that must appear flagged in the analyzer's output. The
   PoC's run_tests.sh is the source of truth for these line numbers. *)

type case = { fixture : string; expected_exit : int; expected_lines : int list }

let cases =
  [
    {
      fixture = "Widening_cases";
      expected_exit = 1;
      expected_lines = [ 25; 37; 64 ];
    };
    {
      fixture = "Edge_cases";
      expected_exit = 1;
      expected_lines = [ 46; 69; 78; 90; 103 ];
    };
    {
      fixture = "Layer_cases";
      expected_exit = 1;
      expected_lines = [ 34; 59; 94; 160; 183 ];
    };
    {
      fixture = "Cross_cu_cases";
      expected_exit = 1;
      expected_lines = [ 40; 71 ];
    };
  ]

(* ============================================================ *)
(* Assertions                                                   *)
(* ============================================================ *)

let lines_referenced (out : string) : int list =
  (* Findings are headed by lines like
     [File "foo.ml", line N, characters X-Y:]. Extract every N. *)
  let re = Str.regexp {|line \([0-9]+\),|} in
  let rec collect i acc =
    match Str.search_forward re out i with
    | exception Not_found -> List.rev acc
    | _ ->
        let n = int_of_string (Str.matched_group 1 out) in
        collect (Str.match_end ()) (n :: acc)
  in
  collect 0 []

let test_case (c : case) () =
  let cmt = cmt_for c.fixture in
  if not (Sys.file_exists cmt) then
    Alcotest.failf "missing fixture cmt: %s (did you run `dune build`?)" cmt;
  let out, code = run_pipeline cmt in
  Alcotest.(check int) "exit code" c.expected_exit code;
  let actual = List.sort_uniq compare (lines_referenced out) in
  let expected = List.sort_uniq compare c.expected_lines in
  Alcotest.(check (list int)) "flagged lines" expected actual

(* ============================================================ *)
(* Wire error contract                                          *)
(* ============================================================ *)

(* The analyzer must exit 2 on malformed ND-JSON, not crash. *)

let pipe_string_to_analyzer (s : string) : int =
  let cmd =
    Printf.sprintf "echo '%s' | %s 2>/dev/null" s (Filename.quote analyze_bin)
  in
  match Unix.system cmd with WEXITED n -> n | _ -> 255

let test_missing_header () =
  Alcotest.(check int)
    "missing header → exit 2" 2
    (pipe_string_to_analyzer
       {|{"kind":"candidate","site_kind":"catch","loc":{"file":"x","line":1,"col":0},"declared":[],"upstream":[]}|})

let test_malformed_candidate () =
  Alcotest.(check int)
    "malformed record → exit 2" 2
    (pipe_string_to_analyzer
       (String.concat "\n"
          [
            {|{"kind":"header","schema_version":1,"ocaml_version":"x","generated_at":"x"}|};
            {|{"kind":"candidate","site_kind":"catch","loc":{}}|};
          ]))

let test_invalid_json () =
  Alcotest.(check int)
    "garbage JSON → exit 2" 2
    (pipe_string_to_analyzer "not even JSON")

(* ============================================================ *)
(* Filesystem error contract                                    *)
(* ============================================================ *)

(* Both binaries must exit 2 (user-error) on a missing path, never
   crash with an uncaught Sys_error / Unix_error. *)

let exit_of_command (cmd : string) : int =
  match Unix.system (cmd ^ " 2>/dev/null >/dev/null") with
  | WEXITED n -> n
  | _ -> 255

let test_extract_missing_input () =
  Alcotest.(check int)
    "extract on missing path → exit 2" 2
    (exit_of_command
       (Printf.sprintf "%s /tmp/hamlet-lint-test-does-not-exist-XYZ"
          (Filename.quote extract_bin)))

let test_extract_missing_exclude () =
  Alcotest.(check int)
    "extract --exclude on missing path → exit 2" 2
    (exit_of_command
       (Printf.sprintf
          "%s --exclude /tmp/hamlet-lint-test-does-not-exist-XYZ \
           /tmp/hamlet-lint-test-does-not-exist-also"
          (Filename.quote extract_bin)))

let test_analyzer_missing_input () =
  Alcotest.(check int)
    "analyzer --input on missing file → exit 2" 2
    (exit_of_command
       (Printf.sprintf "%s --input /tmp/hamlet-lint-test-does-not-exist-XYZ"
          (Filename.quote analyze_bin)))

(* The exclude-prefix bug surfaced by codex: `--exclude /a/foo` must
   not also exclude `/a/foobar`. We can't easily build a real
   directory tree of cmts in the test, but we can check that the
   exclude logic doesn't drop paths whose absolute realpath matches
   the prefix only as a string-prefix-not-path-child. We exercise
   it by running extract on a directory whose name is a string
   superset of an excluded sibling. *)
let test_exclude_prefix_word_boundary () =
  let tmp = Filename.get_temp_dir_name () in
  let suffix = Printf.sprintf "hl-test-%d" (Unix.getpid ()) in
  let root = Filename.concat tmp suffix in
  let bar = Filename.concat root "bar" in
  let barista = Filename.concat root "barista" in
  Unix.mkdir root 0o755;
  Unix.mkdir bar 0o755;
  Unix.mkdir barista 0o755;
  (* copy a known fixture cmt under barista/ *)
  let src = cmt_for "Layer_cases" in
  let dst = Filename.concat barista "L.cmt" in
  let buf = read_all (open_in_bin src) in
  let oc = open_out_bin dst in
  output_string oc buf;
  close_out oc;
  let with_excl =
    let cmd =
      Printf.sprintf "%s --exclude %s %s 2>/dev/null"
        (Filename.quote extract_bin)
        (Filename.quote bar) (Filename.quote root)
    in
    let ic = Unix.open_process_in cmd in
    let s = read_all ic in
    let _ = Unix.close_process_in ic in
    String.length s
  in
  let without_excl =
    let cmd =
      Printf.sprintf "%s %s 2>/dev/null"
        (Filename.quote extract_bin)
        (Filename.quote root)
    in
    let ic = Unix.open_process_in cmd in
    let s = read_all ic in
    let _ = Unix.close_process_in ic in
    String.length s
  in
  Sys.remove dst;
  Unix.rmdir bar;
  Unix.rmdir barista;
  Unix.rmdir root;
  Alcotest.(check int)
    "exclude /tmp/.../bar must not drop /tmp/.../barista/*.cmt" without_excl
    with_excl

let () =
  Alcotest.run "e2e"
    [
      ( "fixtures",
        List.map
          (fun c -> Alcotest.test_case c.fixture `Quick (test_case c))
          cases );
      ( "wire_errors",
        [
          Alcotest.test_case "missing header" `Quick test_missing_header;
          Alcotest.test_case "malformed candidate" `Quick
            test_malformed_candidate;
          Alcotest.test_case "invalid JSON" `Quick test_invalid_json;
        ] );
      ( "fs_errors",
        [
          Alcotest.test_case "extract: missing positional path" `Quick
            test_extract_missing_input;
          Alcotest.test_case "extract: missing --exclude path" `Quick
            test_extract_missing_exclude;
          Alcotest.test_case "analyzer: missing --input path" `Quick
            test_analyzer_missing_input;
          Alcotest.test_case "exclude prefix is path-segment-aware" `Quick
            test_exclude_prefix_word_boundary;
        ] );
    ]
