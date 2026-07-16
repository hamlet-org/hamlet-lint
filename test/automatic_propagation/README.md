# Automatic-propagation acceptance tests

This directory tests the complete path from source text to final compiler and
Merlin output. Unit tests under `subtractor/test` cover the individual proof,
protocol, resolver, and generation modules.

## Run

From the repository root:

```sh
make test
```

The focused acceptance alias is:

```sh
opam exec -- dune build \
  @test/automatic_propagation/automatic-propagation-acceptance
```

Run Dune commands sequentially in this checkout.

## What is checked

The suite verifies:

- exact error and requirement residual types from saved builds;
- final PPX output with no automatic markers or private probe attributes;
- runtime routing for handled, forwarded, guarded, recovery, chained, generic,
  nested-generic, Layer, and requirement cases;
- two or more dependent markers with `catch`, `provide`, `chain`, filters, and
  intervening effects;
- cross-module generated error catalogues;
- generic-helper contracts and two different caller specializations;
- unsaved Merlin buffers, Typedtree output, and hover types;
- dependency `.cmi` changes invalidating the expected elaboration;
- stable diagnostics for every refused fixture.

Layer cases lock exact rows for direct and pipeline catches, every provider
form, primitive tracing, mixed effect flows, and same-module, cross-module, and
nested generic helpers. Runtime checks cover residual forwarding, once-only
source evaluation, provider wiring, and installed-package elaboration. Refused
fixtures cover opaque unwrapping, malformed handlers, wrong marker channels,
noncanonical owners, and direct markers in cause, defect, and `tap_fail`
handlers.

Expected type and expansion files are committed. Update them only after
reviewing why the observable output changed.

## Source-tree resolver dependency

The integration Dune stanzas contain `preprocessor_deps (package
hamlet-subtractor)` because the package is being tested before installation.
That dependency makes the resolver executable exist in the same build context
as the test PPX.

Normal consuming repositories do not add this stanza. An installed PPX finds
the resolver installed with its own package through the Dune package site.

## Installed consumer

The shared installed-consumer harness creates a fresh prefix, installs Hamlet
and Hamlet Subtractor, creates an unrelated consumer project, and checks both
Dune and Merlin against the installed artifacts:

```sh
make installed-consumer
```

For manual editor inspection:

```sh
make installed-consumer-keep
```

The second target runs the same checks and preserves the generated directory.
It prints the project path, a launcher with the isolated package environment,
and cleanup instructions.

## Adding coverage

Add the narrowest layer that proves the behavior:

- pure proof or serialization rule: `subtractor/test`;
- syntax rewrite or diagnostic: PPX unit tests or `negative/`;
- inferred public type: a `.cmt` golden fixture;
- execution behavior: `automatic_propagation_runtime_test.ml`;
- compiler/Merlin lifecycle: `run_acceptance.sh`;
- packaging or resolver discovery: `installed_consumer.sh`.

For a regression that crosses layers, keep a focused unit test and one
end-to-end acceptance case.
