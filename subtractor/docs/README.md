# Hamlet Subtractor Internals

These notes explain how automatic propagation is implemented. They are aimed
at maintainers and contributors who need more detail than the public usage
guide, but do not want to reconstruct the design from compiler-libs code.

Read them in this order:

1. [Architecture and Data Flow](./architecture.md) follows a source marker from
   the PPX input through the probe, evidence resolver, engine, and final AST.
2. [Proof and Soundness Model](./proof-model.md) explains exact rows, nominal
   leaves, catalogues, residual subtraction, recovery certificates, dependent
   markers, and refusal boundaries.
3. [Compiler and Editor Integration](./integration.md) explains Dune modes,
   compiler-state isolation, the resolver protocol, Merlin and OCaml-LSP,
   diagnostics, packaging, and the acceptance harness.

For normal application usage, start with
[Automatic Propagation](../../docs/automatic-propagation.md) instead.

## Reading the code

The implementation is split deliberately:

- `subtractor/core` contains compiler-independent proof values and algorithms.
- `subtractor/hamlet_subtractor_probe.ml` prepares a type-safe temporary AST.
- `subtractor/hamlet_subtractor_compiler_evidence.ml` converts Typedtree
  evidence into immutable subtractor proofs.
- `subtractor/hamlet_subtractor_engine.ml` resolves marker dependencies.
- `subtractor/hamlet_subtractor_generator.ml` and
  `hamlet_subtractor_replace.ml` create the final ordinary OCaml AST.
- `subtractor/hamlet_subtractor_ppx.ml` owns the complete PPX lifecycle.
- `subtractor/hamlet_subtractor_resolver.ml` exposes the isolated resolver path through the
  same normalized protocol.

The final compiler and Merlin never type the temporary probe as user code.
They type only the final expansion returned by `hamlet-subtractor.ppx`.

Installed PPXs locate the resolver through the `hamlet-subtractor` Dune site.
This repository's uninstalled source-tree fixture uses a same-context lookup
derived from the running `.ppx` executable, with an explicit build dependency
that is not needed by consuming repositories. Neither mode searches `PATH`.

The historical `hamlet-lint` repository provided the Typedtree-analysis basis
for this package. Its old packages and commands are historical. This project
installs no lint CLI: automatic propagation is delivered only through the PPX
and its installation-relative resolver.
