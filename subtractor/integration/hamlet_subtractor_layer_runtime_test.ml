let () =
  ignore (Hamlet.Interpreter.run Hamlet_subtractor_layer_fixture.counted_effect);
  if !Hamlet_subtractor_layer_fixture.upstream_evaluations <> 1 then
    failwith "Layer.catch evaluated its primary expression more than once"
