let passthrough source _evidence = source

let source : (unit, [ `Missing ], Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail `Missing

let result = passthrough source [%hamlet.forward.auto]
