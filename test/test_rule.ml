(** Rule-level tests for the analyzer. These drive the §2.3 check directly with
    hand-built schema records, so they exercise the linter semantics without
    needing a working extractor or compiled fixtures.

    The companion end-to-end test for the extractor pipeline lives separately
    (and is only wired when an OCaml 5.4 toolchain and a built Hamlet library
    are available — see README.md, section "How to add a new test case"). *)

open Hamlet_lint_schema.Schema
module Rule = Hamlet_lint_analyzer.Rule

let loc0 = { file = "t.ml"; line = 1; col = 0 }

let mk_arm ?(body_introduces = []) ?(action = Forward) tag =
  { tag; action; body_introduces; loc = loc0 }

let mk_row ?(in_lb = []) ?(wildcard = false) ~out_lb arms =
  {
    in_lower_bound = Some in_lb;
    out_lower_bound = out_lb;
    handler = { has_wildcard_forward = wildcard; arms };
  }

let mk_services_site ?(in_lb = []) ?(wildcard = false) ~out_lb arms :
    concrete_site =
  {
    loc = loc0;
    kind = Combinators_provide;
    services = Some (mk_row ~in_lb ~wildcard ~out_lb arms);
    errors = None;
  }

let mk_errors_site
    ?(kind = Combinators_catch)
    ?(in_lb = [])
    ?(wildcard = false)
    ~out_lb
    arms : concrete_site =
  {
    loc = loc0;
    kind;
    services = None;
    errors = Some (mk_row ~in_lb ~wildcard ~out_lb arms);
  }

let finding_tags findings =
  List.map (fun (f : Rule.finding) -> f.tag) findings |> List.sort compare

let check_tags name expected findings =
  Alcotest.(check (list string)) name expected (finding_tags findings)

(* ---------------------------------------------------------------- *)
(*  Services row                                                    *)
(* ---------------------------------------------------------------- *)

(** §2.4 canonical example: in_lb=[Console], out_lb=[Console; Logger; Database],
    two Forward arms -> two findings. *)
let test_stale_services () =
  let site =
    mk_services_site ~in_lb:[ "Console" ]
      ~out_lb:[ "Console"; "Database"; "Logger" ]
      [
        mk_arm ~action:Discharge "Console";
        mk_arm ~action:Forward "Logger";
        mk_arm ~action:Forward "Database";
      ]
  in
  check_tags "stale services" [ "Database"; "Logger" ]
    (Rule.check_concrete site)

(** Pure-give: every arm Discharge, out_lb - in_lb is empty so no findings
    regardless of shape. *)
let test_clean_services () =
  let site =
    mk_services_site
      ~in_lb:[ "Console"; "Logger"; "Database" ]
      ~out_lb:[]
      [
        mk_arm ~action:Discharge "Console";
        mk_arm ~action:Discharge "Logger";
        mk_arm ~action:Discharge "Database";
      ]
  in
  check_tags "clean services" [] (Rule.check_concrete site)

(** Wildcard suppression (§2.7): even with stale-looking Forward arms, a
    wildcard Forward silences the row. *)
let test_wildcard_suppression () =
  let site =
    mk_services_site ~in_lb:[ "Console" ] ~out_lb:[ "Console"; "Logger" ]
      ~wildcard:true
      [ mk_arm ~action:Discharge "Console" ]
  in
  check_tags "wildcard suppression" [] (Rule.check_concrete site)

(* ---------------------------------------------------------------- *)
(*  Errors row                                                      *)
(* ---------------------------------------------------------------- *)

(** §2.5 canonical: in_lb=[NotFound], Forward arms Timeout+Forbidden both stale
    -> two findings. *)
let test_stale_errors () =
  let site =
    mk_errors_site ~in_lb:[ "NotFound" ] ~out_lb:[ "Forbidden"; "Timeout" ]
      [
        mk_arm ~action:Discharge "NotFound";
        mk_arm ~action:Forward "Timeout";
        mk_arm ~action:Forward "Forbidden";
      ]
  in
  check_tags "stale errors" [ "Forbidden"; "Timeout" ]
    (Rule.check_concrete site)

(** §2.3.b legitimate body introducer: the arm body's 'e lb contains the phantom
    tag, so the analyzer attributes it to the body, not to a missing arm. No
    finding. *)
let test_errors_legit_body_introducer () =
  let site =
    mk_errors_site ~in_lb:[ "Foo" ] ~out_lb:[ "Bar" ]
      [
        (* Arm is `Foo -> failure `Bar: the body's inferred 'e lb is
           [Bar], so Bar is attributable to this body introducer. *)
        mk_arm ~body_introduces:[ "Bar" ] ~action:Forward "Foo";
      ]
  in
  check_tags "errors legit body" [] (Rule.check_concrete site)

(** map_error stale arm: for [map_error] the arm pattern tag equals the body
    output tag, so we encode the stale body output directly as a Forward arm
    (with empty [body_introduces], since §2.3.b would otherwise suppress the
    grown tag). *)
let test_map_error_stale () =
  let site =
    (* map_error encodes: arm pattern tag = body output tag when the
       body is `D, so we record the body tag as the arm tag here. *)
    mk_errors_site ~kind:Combinators_map_error ~in_lb:[ "A" ]
      ~out_lb:[ "A"; "D" ]
      [ mk_arm ~action:Discharge "A"; mk_arm ~action:Forward "D" ]
  in
  check_tags "map_error stale" [ "D" ] (Rule.check_concrete site)

(* ---------------------------------------------------------------- *)
(*  Latent wrapper                                                  *)
(* ---------------------------------------------------------------- *)

(** Latent site: the wrapper function's in_lb is None; the join against a call
    site whose arg has in_lb=[Console; Logger] materialises the phantom at the
    *outer* call location. *)
let test_latent_join () =
  let lat : latent_site =
    {
      loc = { loc0 with line = 10 };
      kind = Combinators_provide;
      latent_in_function = "Test.wrap";
      services =
        Some
          {
            in_lower_bound = None;
            out_lower_bound = [ "Database" ];
            handler =
              {
                has_wildcard_forward = false;
                arms = [ mk_arm ~action:Forward "Database" ];
              };
          };
      errors = None;
    }
  in
  let call1 : call_site =
    {
      function_path = "Test.wrap";
      loc = { loc0 with line = 100 };
      arg_loc = { loc0 with line = 100 };
      arg_services_lb = Some [ "Console" ];
      arg_errors_lb = None;
    }
  in
  let findings = Rule.analyze [ Latent lat; Call call1 ] in
  check_tags "latent phantom at outer call" [ "Database" ] findings

let () =
  Alcotest.run "hamlet-lint-rule"
    [
      ( "services",
        [
          Alcotest.test_case "stale" `Quick test_stale_services;
          Alcotest.test_case "clean pure-give" `Quick test_clean_services;
          Alcotest.test_case "wildcard suppression" `Quick
            test_wildcard_suppression;
        ] );
      ( "errors",
        [
          Alcotest.test_case "stale" `Quick test_stale_errors;
          Alcotest.test_case "legit body introducer" `Quick
            test_errors_legit_body_introducer;
          Alcotest.test_case "map_error stale" `Quick test_map_error_stale;
        ] );
      ("latent", [ Alcotest.test_case "wrapper join" `Quick test_latent_join ]);
    ]
