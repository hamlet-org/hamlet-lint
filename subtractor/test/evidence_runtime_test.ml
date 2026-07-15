module Evidence = Hamlet_subtractor.Evidence

type input_error = [ `Missing | `Timeout ]
type output_error = [ `Timeout ]
type handled_error = [ `Missing ]

type input_requirement = [ `Clock | `Logger ]
type output_requirement = [ `Clock ]
type handled_requirement = [ `Logger ]

let error_slot : (input_error, output_error, handled_error) Evidence.slot =
  {
    dispatch =
      (fun input ~handled ~forward ->
        match input with
        | `Missing -> handled `Missing
        | `Timeout -> forward `Timeout);
  }

let requirement_slot :
    (input_requirement, output_requirement, handled_requirement) Evidence.slot =
  {
    dispatch =
      (fun input ~handled ~forward ->
        match input with `Logger -> handled `Logger | `Clock -> forward `Clock);
  }

let test_result_polymorphism_and_tuple_typing () =
  let bundle = (error_slot, requirement_slot) in
  let first, second = bundle in
  let integer =
    first.dispatch `Missing ~handled:(fun _ -> 1) ~forward:(fun _ -> 2)
  in
  let string =
    first.dispatch `Timeout
      ~handled:(fun _ -> "handled")
      ~forward:(fun _ -> "forwarded")
  in
  let requirement =
    second.dispatch `Logger ~handled:(fun _ -> true) ~forward:(fun _ -> false)
  in
  Alcotest.(check int) "integer result" 1 integer;
  Alcotest.(check string) "string result" "forwarded" string;
  Alcotest.(check bool) "requirement handled" true requirement

let () =
  Alcotest.run "hamlet-subtractor-evidence-runtime"
    [
      ( "evidence",
        [
          Alcotest.test_case "result-polymorphic tuple slots" `Quick
            test_result_polymorphism_and_tuple_typing;
        ] );
    ]
