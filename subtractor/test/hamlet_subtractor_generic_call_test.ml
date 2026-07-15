open Ppxlib

let parse source = Parse.implementation (Lexing.from_string source)

let count_attribute name structure =
  let count = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! attribute attribute =
        if String.equal attribute.attr_name.txt name then incr count;
        super#attribute attribute
    end
  in
  iterator#structure structure;
  !count

let count_extension structure =
  let count = ref 0 in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        (match expression.pexp_desc with
        | Pexp_extension ({ txt = "hamlet.forward.auto"; _ }, PStr []) ->
            incr count
        | _ -> ());
        super#expression expression
    end
  in
  iterator#structure structure;
  !count

let prepare source = source |> parse |> Hamlet_subtractor_generic_call.prepare

let check_single_call () =
  let prepared =
    prepare "let value = helper config source [%hamlet.forward.auto]"
  in
  Alcotest.(check int) "one call" 1 (List.length prepared.calls);
  Alcotest.(check int) "no refusals" 0 (List.length prepared.refusals);
  Alcotest.(check int)
    "base keeps extension" 1
    (count_extension prepared.base_structure);
  Alcotest.(check int)
    "probe removes extension" 0
    (count_extension prepared.probe_structure);
  Alcotest.(check int)
    "call link" 1
    (count_attribute Hamlet_subtractor_generic_call.call_attribute
       prepared.probe_structure);
  Alcotest.(check int)
    "callee link" 1
    (count_attribute Hamlet_subtractor_generic_call.callee_attribute
       prepared.probe_structure);
  Alcotest.(check int)
    "source link" 1
    (count_attribute Hamlet_subtractor_generic_call.source_attribute
       prepared.probe_structure);
  Alcotest.(check int)
    "placeholder link" 1
    (count_attribute Hamlet_subtractor_generic_call.placeholder_attribute
       prepared.probe_structure)

let check_distinct_ids () =
  let prepared =
    prepare
      "let first = helper source_a [%hamlet.forward.auto]\n\
       let second = helper source_b [%hamlet.forward.auto]"
  in
  match prepared.calls with
  | [ first; second ] ->
      Alcotest.(check bool)
        "stable IDs differ" true
        (not (String.equal first.id second.id))
  | calls -> Alcotest.failf "expected two calls, got %d" (List.length calls)

let check_refusal source expected =
  let prepared = prepare source in
  match prepared.refusals with
  | [ { reason; _ } ] -> Alcotest.(check bool) "reason" true (reason = expected)
  | refusals ->
      Alcotest.failf "expected one refusal, got %d" (List.length refusals)

let check_nonfinal () =
  check_refusal "let value = helper [%hamlet.forward.auto] source"
    Hamlet_subtractor_generic_call.Not_a_final_argument

let check_labelled () =
  check_refusal "let value = helper source ~evidence:[%hamlet.forward.auto]"
    Hamlet_subtractor_generic_call.Labelled_argument

let check_missing_effect () =
  check_refusal "let value = helper [%hamlet.forward.auto]"
    Hamlet_subtractor_generic_call.Missing_effect_argument

let check_multiple () =
  check_refusal
    "let value = helper source [%hamlet.forward.auto] [%hamlet.forward.auto]"
    Hamlet_subtractor_generic_call.Multiple_placeholders

let check_pipeline () =
  check_refusal "let value = source |> helper config [%hamlet.forward.auto]"
    Hamlet_subtractor_generic_call.Pipeline_application

let () =
  Alcotest.run "generic helper call probe"
    [
      ( "preparation",
        [
          Alcotest.test_case "single direct call" `Quick check_single_call;
          Alcotest.test_case "distinct call identities" `Quick
            check_distinct_ids;
        ] );
      ( "refusals",
        [
          Alcotest.test_case "non-final placeholder" `Quick check_nonfinal;
          Alcotest.test_case "labelled placeholder" `Quick check_labelled;
          Alcotest.test_case "missing effect argument" `Quick
            check_missing_effect;
          Alcotest.test_case "multiple placeholders" `Quick check_multiple;
          Alcotest.test_case "pipeline application" `Quick check_pipeline;
        ] );
    ]
