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

let prepare source = source |> parse |> Hamlet_subtractor_generic_call.prepare

let check_single_call () =
  let prepared = prepare "let value = helper config source" in
  Alcotest.(check int) "one candidate" 1 (List.length prepared.calls);
  Alcotest.(check int) "no refusals" 0 (List.length prepared.refusals);
  Alcotest.(check int)
    "call link" 1
    (count_attribute Hamlet_subtractor_generic_call.call_attribute
       prepared.probe_structure);
  Alcotest.(check int)
    "callee link" 1
    (count_attribute Hamlet_subtractor_generic_call.callee_attribute
       prepared.probe_structure);
  Alcotest.(check int)
    "source chosen by resolver" 0
    (count_attribute Hamlet_subtractor_generic_call.source_attribute
       prepared.probe_structure)

let check_distinct_ids () =
  let prepared =
    prepare "let first = helper source_a\nlet second = helper source_b"
  in
  match prepared.calls with
  | [ first; second ] ->
      Alcotest.(check bool)
        "stable IDs differ" true
        (not (String.equal first.id second.id))
  | calls -> Alcotest.failf "expected two calls, got %d" (List.length calls)

let check_stable_ids () =
  let source = "let value = helper ~config source" in
  let first = prepare source in
  let second = prepare source in
  match (first.calls, second.calls) with
  | [ first ], [ second ] ->
      Alcotest.(check string) "stable candidate ID" first.id second.id
  | _ -> Alcotest.fail "expected one candidate in each preparation"

let check_labelled_arguments () =
  let prepared = prepare "let value = helper ~mode:`Strict config source" in
  Alcotest.(check int) "one labelled candidate" 1 (List.length prepared.calls);
  Alcotest.(check int)
    "labelled call has no syntax refusal" 0
    (List.length prepared.refusals)

let check_direct_combinator_context () =
  let prepared =
    prepare
      "let value = Hamlet.Combinators.catch (helper source) ~handler:(fun \
       error -> Hamlet.Combinators.fail error)"
  in
  Alcotest.(check int)
    "helper and enclosing combinator are independently classified" 3
    (List.length prepared.calls);
  Alcotest.(check int)
    "every direct call is linked" 3
    (count_attribute Hamlet_subtractor_generic_call.call_attribute
       prepared.probe_structure)

let check_nested_direct_candidates () =
  let prepared = prepare "let value = outer (middle (inner source))" in
  Alcotest.(check int)
    "three nested direct candidates" 3
    (List.length prepared.calls);
  let ids =
    List.map
      (fun (call : Hamlet_subtractor_generic_call.call) -> call.id)
      prepared.calls
  in
  Alcotest.(check int)
    "all nested IDs are distinct" 3
    (List.sort_uniq String.compare ids |> List.length)

let check_ordinary_call_can_be_ignored () =
  let prepared = prepare "let value = ordinary_identity 42" in
  let payload =
    Hamlet_subtractor_core.Generic_resolution.encode_ignored_call ()
    |> Result.get_ok
  in
  let attachments =
    List.map
      (fun (call : Hamlet_subtractor_generic_call.call) ->
        Hamlet_subtractor_core.Protocol.generic_attachment ~id:call.id
          ~kind:Hamlet_subtractor_core.Protocol.Call ~payload
        |> Result.get_ok)
      prepared.calls
  in
  let finalized =
    Hamlet_subtractor_generic_call.finalize ~calls:prepared.calls ~attachments
      ~catalogues:[] prepared.base_structure
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "ignored ordinary call is structurally unchanged" true
    (prepared.base_structure = finalized)

let check_non_call () =
  let prepared = prepare "let value = 42" in
  Alcotest.(check int) "no candidate" 0 (List.length prepared.calls)

let check_legacy_extension () =
  let prepared = prepare "let value = helper source [%hamlet.forward.auto]" in
  match prepared.refusals with
  | [ { reason = Hamlet_subtractor_generic_call.Legacy_forward_extension; _ } ]
    ->
      ()
  | refusals ->
      Alcotest.failf "expected one legacy-syntax refusal, got %d"
        (List.length refusals)

let () =
  Alcotest.run "generic helper call probe"
    [
      ( "preparation",
        [
          Alcotest.test_case "single direct call" `Quick check_single_call;
          Alcotest.test_case "distinct call identities" `Quick
            check_distinct_ids;
          Alcotest.test_case "stable call identity" `Quick check_stable_ids;
          Alcotest.test_case "labelled ordinary arguments" `Quick
            check_labelled_arguments;
          Alcotest.test_case "direct combinator context" `Quick
            check_direct_combinator_context;
          Alcotest.test_case "nested direct candidates" `Quick
            check_nested_direct_candidates;
          Alcotest.test_case "ordinary call is ignored" `Quick
            check_ordinary_call_can_be_ignored;
          Alcotest.test_case "non-call expression" `Quick check_non_call;
          Alcotest.test_case "legacy extension" `Quick check_legacy_extension;
        ] );
    ]
