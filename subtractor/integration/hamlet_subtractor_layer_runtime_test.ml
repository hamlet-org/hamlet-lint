open Hamlet

module Fixture = Hamlet_subtractor_layer_fixture

module Clock_live = Fixture.Clock.Make (struct
  let now () = Combinators.return 42
end)

let provide_clock computation =
  Combinators.provide computation ~handler:(function
      | #Fixture.Clock.Tag.r as witness ->
      Fixture.Clock.Tag.give witness (module Clock_live))

let expect_success label computation =
  match Interpreter.run computation with
  | Ok _ -> ()
  | Error _ -> failwith (label ^ " unexpectedly failed")

let expect_counted_forwarding () =
  begin match Interpreter.run Fixture.counted_effect with
  | Error `Timeout -> ()
  | Ok _ -> failwith "Layer.catch swallowed the forwarded Timeout"
  end;
  if !Fixture.upstream_evaluations <> 1 then
    failwith "Layer.catch evaluated its primary expression more than once"

let expect_explicit_boundary_forwarding () =
  let computation =
    Layer.provide_to_effect ~source:Fixture.case_layer_explicit_boundary
      ~handler:(fun logger -> function
        | #Fixture.Logger.Tag.r as witness ->
            Fixture.Logger.Tag.give witness logger)
      Fixture.Logger.Tag.summon
  in
  match Interpreter.run computation with
  | Error `Timeout -> ()
  | Ok _ -> failwith "explicit Layer boundary swallowed the fallback Timeout"

let expect_structural_forwarding () =
  let computation =
    Layer.provide_to_effect ~source:Fixture.case_layer_structural
      ~handler:(fun logger -> function
        | #Fixture.Logger.Tag.r as witness ->
            Fixture.Logger.Tag.give witness logger)
      Fixture.Logger.Tag.summon
  in
  match Interpreter.run computation with
  | Error (`Layer_timeout 42) -> ()
  | Error (`Layer_timeout _) ->
      failwith "Layer.catch changed the structural residual payload"
  | Ok _ -> failwith "Layer.catch swallowed the structural residual error"

let expect_cross_cu_forwarding () =
  let computation =
    Layer.provide_to_effect ~source:Fixture.case_layer_cross_cu_catalogue
      ~handler:(fun logger -> function
        | #Fixture.Logger.Tag.r as witness ->
            Fixture.Logger.Tag.give witness logger)
      Fixture.Logger.Tag.summon
  in
  match Interpreter.run computation with
  | Error (`Read_error "read") -> ()
  | Error (`Read_error _) ->
      failwith "Layer.catch changed the cross-CU residual payload"
  | Error (`Write_error _) ->
      failwith "Layer.catch forwarded the wrong cross-CU residual member"
  | Ok _ -> failwith "Layer.catch swallowed the cross-CU residual error"

let run_metrics_layer layer =
  Layer.provide_to_effect ~source:layer
    ~handler:(fun metrics -> function
      | #Fixture.Metrics.Tag.r as witness ->
          Fixture.Metrics.Tag.give witness metrics)
    Fixture.Metrics.Tag.summon
  |> provide_clock

let expect_provider_matrix () =
  Fixture.case_layer_provide_to_effect_direct
  |> provide_clock
  |> expect_success "direct provide_to_effect";
  Fixture.case_layer_provide_to_effect_pipeline
  |> provide_clock
  |> expect_success "pipeline provide_to_effect";
  Fixture.case_layer_provide_to_layer_direct
  |> run_metrics_layer
  |> expect_success "direct provide_to_layer";
  Fixture.case_layer_provide_to_layer_pipeline
  |> run_metrics_layer
  |> expect_success "pipeline provide_to_layer";
  Fixture.case_layer_provide_merge_to_layer_direct
  |> run_metrics_layer
  |> expect_success "direct provide_merge_to_layer";
  Fixture.case_layer_provide_merge_to_layer_pipeline
  |> run_metrics_layer
  |> expect_success "pipeline provide_merge_to_layer"

let run_logger_layer layer =
  Layer.provide_to_effect ~source:layer
    ~handler:(fun logger -> function
      | #Fixture.Logger.Tag.r as witness ->
          Fixture.Logger.Tag.give witness logger)
    Fixture.Logger.Tag.summon

let expect_generic_unwrap_and_optional_fresh () =
  begin match
    Fixture.case_layer_generic_unwrap_output_to_later_marker
    |> run_logger_layer
    |> Interpreter.run
  with
  | Error `Timeout -> ()
  | Ok _ -> failwith "generic Layer.unwrap swallowed Timeout"
  end;
  begin match
    Fixture.case_layer_optional_fresh_direct
    |> run_logger_layer
    |> Interpreter.run
  with
  | Error `Timeout -> ()
  | Ok _ -> failwith "direct optional fresh swallowed Timeout"
  end;
  begin match
    Fixture.case_layer_optional_fresh_pipeline
    |> run_logger_layer
    |> Interpreter.run
  with
  | Error `Timeout -> ()
  | Ok _ -> failwith "pipeline optional fresh swallowed Timeout"
  end;
  if !Fixture.optional_direct_evaluations <> 1 then
    failwith "direct optional fresh evaluated its upstream more than once";
  if !Fixture.optional_pipeline_evaluations <> 1 then
    failwith "pipeline optional fresh evaluated its upstream more than once"

let expect_try_catch_unwrap_recovery () =
  Fixture.case_layer_trace_unwrap_try_catch
  |> run_logger_layer
  |> expect_success "try_catch Layer.unwrap recovery"

let () =
  expect_counted_forwarding ();
  expect_explicit_boundary_forwarding ();
  expect_structural_forwarding ();
  expect_cross_cu_forwarding ();
  expect_provider_matrix ();
  expect_generic_unwrap_and_optional_fresh ();
  expect_try_catch_unwrap_recovery ()
