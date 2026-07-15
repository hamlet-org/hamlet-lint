# Automatic propagation acceptance tests

This directory tests the public feature through real Dune, Merlin, and
OCaml-LSP entry points. The fixtures use separate compilation units so the PPX
must read actual dependency interfaces rather than seeing every declaration in
one file.

## Run the tests

From the repository root:

```sh
dune runtest test/automatic_propagation
```

This is the complete feature gate. It checks:

- final inferred types and runtime behavior;
- saved and unsaved OCaml-LSP hovers;
- the final source and Typedtree seen by raw Merlin;
- invalidation after a dependency interface changes;
- expected refusals and explicit fallbacks;
- arbitrarily long linear marker chains, including effects introduced between
  markers, alternating `chain` and `catch`, the catch-filter family, and
  refusal of a two-predecessor marker merge;
- linear generation for cross-module `Errors.Cases` catalogues.

The same gate is available as
`@test/automatic_propagation/automatic-propagation-acceptance` or by running
`test/automatic_propagation/run_acceptance.sh`. The focused LSP session is
`@test/automatic_propagation/automatic-propagation-lsp`.

The active opam switch must provide `ocamlmerlin` and `ocamllsp`.

## Why this checkout has `preprocessor_deps`

The positive fixture contains:

```lisp
(preprocessor_deps
 (package hamlet-subtractor))
```

The package is not installed while these tests run, so this dependency makes
Dune build the resolver executable before Merlin starts the PPX. Installed
projects do not need it: their resolver is installed with the package.

## Installed consumer

`make installed-consumer` installs the package into a temporary prefix and
tests a separate project whose only PPX configuration is:

```lisp
(staged_pps hamlet-subtractor.ppx)
```

This catches accidental dependencies on the source checkout. It verifies the
runtime result, exact Merlin hovers, and the installed resolver path. Its
generated `main.ml` includes:

- three automatic catches that handle old and newly introduced errors;
- alternating automatic catches, direct `chain`, and an ordinary error-row
  replacing `catch`;
- a requirement chain that introduces `Metrics` after providing `Logger`, then
  proves that providing `Clock` leaves only `Metrics`.

Use `make installed-consumer-keep` to preserve those examples as a real fixture
project. The command prints its location, editor launch commands, and a cleanup
command. Close the editor before cleanup because an editor process may still be
using the temporary opam paths.

## Adding coverage

- Add successful `case_*` bindings to
  `automatic_propagation_positive.ml`; their exposed rows enter the type
  golden.
- Add runtime behavior to `automatic_propagation_runtime_test.ml`.
- Add refused programs under `negative/` and record stable diagnostic fragments
  in `automatic_propagation_diagnostics.expected`.
- Add cross-module service declarations to
  `automatic_propagation_external.ml`.

The expansion golden must come from raw Merlin output produced by the automatic
implementation, never from an explicit `%hamlet.te` or `%hamlet.ts` stand-in.
