# Changelog

## Unreleased

- Add automatic propagation for exact Hamlet error and service-requirement
  rows through `[%hamlet.propagate_e.auto]` and
  `[%hamlet.propagate_s.auto]`.
- Support dependent markers across verified Hamlet composition, including
  alternating `catch` and `provide`, chaining, filters, scope, and resource
  primitives.
- Add generic automatic helpers with `let[@hamlet.generic]` definitions and
  caller specialization through a final `[%hamlet.forward.auto]` argument.
- Export symbolic helper contracts through generated companion declarations so
  separate compilation and nested generic helpers do not require body inlining.
- Run Typedtree evidence collection in a matching isolated resolver process and
  return only immutable proof values to the PPX.
- Add saved-build, runtime, Merlin, unsaved-buffer, cross-module, negative, and
  installed-consumer acceptance coverage.
