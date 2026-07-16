let specialize source_callback =
  let source = source_callback () in
  Hamlet_subtractor_generic_helper_producer.scoped_then_provide_metrics
    (module Hamlet_subtractor_generic_helper_producer.Logger_live)
    source
