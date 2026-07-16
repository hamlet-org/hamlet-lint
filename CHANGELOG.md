# Changelog

## Unreleased

- Add automatic propagation for exact Hamlet error and service-requirement
  rows through `[%hamlet.propagate_e.auto]` and
  `[%hamlet.propagate_s.auto]`.
- Support dependent markers across verified Hamlet composition, including
  alternating `catch` and `provide`, chaining, filters, scope, and resource
  primitives.
- Support exact Layer error and requirement propagation through `Layer.catch`
  and the Layer provider family, including generic Layer helpers and traced
  Layer transformations.
- Add generic automatic helpers with `let[@hamlet.generic]` definitions and
  automatic specialization at direct calls; caller source needs no annotation.
- Export symbolic helper contracts through generated companion declarations so
  separate compilation and nested generic helpers do not require body inlining.
- Run Typedtree evidence collection in a matching isolated resolver process and
  return only immutable proof values to the PPX.
- Add saved-build, runtime, Merlin, unsaved-buffer, cross-module, negative, and
  installed-consumer acceptance coverage.
