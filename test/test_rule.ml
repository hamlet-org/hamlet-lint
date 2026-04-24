(** Unit tests for the analyzer rule. Hand-built schema records, no extractor /
    fixtures involved — exercise the rule logic in isolation. *)

module S = Hamlet_lint_schema.Schema
module Rule = Hamlet_lint_analyzer.Rule

let loc : S.loc = { file = "x.ml"; line = 1; col = 0 }

let mk_candidate
    ?(kind = S.Catch)
    ?(combinator = "catch")
    ~declared
    ~upstream
    () : S.candidate =
  { loc; kind; combinator; declared; upstream }

let testable_finding =
  let pp ppf (f : Rule.finding) =
    Format.fprintf ppf "{kind=%s; declared=[%s]; upstream=[%s]; extra=[%s]}"
      (match f.kind with Catch -> "catch" | Provide -> "provide")
      (String.concat ";" f.declared)
      (String.concat ";" f.upstream)
      (String.concat ";" f.extra)
  in
  let eq (a : Rule.finding) (b : Rule.finding) =
    a.kind = b.kind
    && a.declared = b.declared
    && a.upstream = b.upstream
    && a.extra = b.extra
  in
  Alcotest.testable pp eq

(* ============================================================ *)

let check_extra_when_declared_wider () =
  let c = mk_candidate ~declared:[ "A"; "B"; "C" ] ~upstream:[ "A" ] () in
  match Rule.check c with
  | None -> Alcotest.fail "expected a finding"
  | Some f ->
      Alcotest.(check (list string))
        "extra is declared minus upstream" [ "B"; "C" ] f.extra

let no_finding_when_declared_subset () =
  let c = mk_candidate ~declared:[ "A" ] ~upstream:[ "A"; "B" ] () in
  Alcotest.(check (option testable_finding)) "no finding" None (Rule.check c)

let no_finding_when_equal () =
  let c = mk_candidate ~declared:[ "A"; "B" ] ~upstream:[ "A"; "B" ] () in
  Alcotest.(check (option testable_finding)) "no finding" None (Rule.check c)

let provide_kind_passthrough () =
  let c = mk_candidate ~kind:Provide ~declared:[ "Db" ] ~upstream:[] () in
  match Rule.check c with
  | None -> Alcotest.fail "expected a finding"
  | Some f ->
      Alcotest.(check string)
        "kind is provide" "provide"
        (match f.kind with Catch -> "catch" | Provide -> "provide")

let analyze_filters_headers_and_collects () =
  let h : S.record =
    Header { schema_version = 1; ocaml_version = "5.4.1"; generated_at = "x" }
  in
  let bad = mk_candidate ~declared:[ "A"; "B" ] ~upstream:[ "A" ] () in
  let good = mk_candidate ~declared:[ "A" ] ~upstream:[ "A" ] () in
  let findings =
    Rule.analyze [ h; S.Candidate bad; S.Candidate good; S.Candidate bad ]
  in
  Alcotest.(check int) "two findings" 2 (List.length findings)

(* Lock in the classifier's Hamlet-root check. We test the production
   predicate directly (not a copy) by linking [hamlet_lint_extract] from
   test/dune and constructing a [Path.Pident] of the given identifier
   name. *)

module Classify = Hamlet_lint_extract.Classify

let root_accepts (name : string) : bool =
  let id = Ident.create_local name in
  Classify.path_root_is_hamlet (Path.Pident id)

let test_root_accepts_hamlet () =
  Alcotest.(check bool) "Hamlet" true (root_accepts "Hamlet");
  Alcotest.(check bool)
    "Hamlet__Combinators" true
    (root_accepts "Hamlet__Combinators");
  Alcotest.(check bool) "Hamlet__" true (root_accepts "Hamlet__")

let test_root_rejects_lookalikes () =
  Alcotest.(check bool) "Hamlet_lint" false (root_accepts "Hamlet_lint");
  Alcotest.(check bool) "HamletFoo" false (root_accepts "HamletFoo");
  Alcotest.(check bool) "Hamleton" false (root_accepts "Hamleton");
  Alcotest.(check bool) "hamlet (lowercase)" false (root_accepts "hamlet");
  Alcotest.(check bool) "" false (root_accepts "");
  Alcotest.(check bool) "Other" false (root_accepts "Other")

let () =
  Alcotest.run "rule"
    [
      ( "check",
        [
          Alcotest.test_case "extra = declared \\ upstream" `Quick
            check_extra_when_declared_wider;
          Alcotest.test_case "subset → no finding" `Quick
            no_finding_when_declared_subset;
          Alcotest.test_case "equal → no finding" `Quick no_finding_when_equal;
          Alcotest.test_case "provide kind preserved" `Quick
            provide_kind_passthrough;
        ] );
      ( "analyze",
        [
          Alcotest.test_case "skips header, collects candidates" `Quick
            analyze_filters_headers_and_collects;
        ] );
      ( "hamlet_root_check",
        [
          Alcotest.test_case "accepts Hamlet / Hamlet__*" `Quick
            test_root_accepts_hamlet;
          Alcotest.test_case "rejects lookalikes" `Quick
            test_root_rejects_lookalikes;
        ] );
    ]
