let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail `Timeout

let recover = Hamlet_subtractor_generic_helper_producer.recover_missing
let result = recover source [%hamlet.forward.auto]
