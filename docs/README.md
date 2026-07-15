# Hamlet Subtractor documentation

Start with the guide that matches your task:

- [Automatic Propagation](./automatic-propagation.md) explains how to use the
  feature in an application.
- [Architecture](./architecture.md) follows one marker through the
  implementation.
- [Proof Model](./proof-model.md) defines the evidence required before code can
  be generated.
- [Compiler and Editor Integration](./integration.md) explains Dune, the
  resolver process, Merlin, and OCaml-LSP.

## The implementation in one minute

An automatic marker asks Hamlet to forward whatever the preceding handler arms
did not handle. A syntax rewriter cannot safely determine that set from source
text alone: an OCaml type may be open, abstract, or widened by its context.

The PPX therefore creates two syntax trees:

- the **base AST** is the user's program and will become the final output;
- the **probe AST** is a temporary copy containing extra links that let the
  OCaml type checker identify the marker, its handler, and its input value.

A separate resolver process type-checks the probe and returns a small,
compiler-independent proof. The PPX subtracts the handled effects, generates
ordinary forwarding cases, and inserts them into the base AST. The normal OCaml
compiler or Merlin then type-checks that final AST. The probe is never compiled
as user code.

## Source map

| Path | Responsibility |
| --- | --- |
| `subtractor/core` | Defines exact rows, certificates, residuals, and their algorithms without depending on OCaml compiler data structures. |
| `subtractor/hamlet_subtractor_probe.ml` | Finds markers and builds the linked base and probe ASTs. |
| `subtractor/hamlet_subtractor_compiler_evidence.ml` | Reads the probe Typedtree, verifies real Hamlet definitions, and produces immutable proofs. |
| `subtractor/hamlet_subtractor_engine.ml` | Subtracts handled leaves and resolves dependencies between markers. |
| `subtractor/hamlet_subtractor_generator.ml` | Generates ordinary forwarding cases from a proven residual. |
| `subtractor/hamlet_subtractor_replace.ml` | Inserts generated cases and type constraints into the base AST. |
| `subtractor/hamlet_subtractor_ppx.ml` | Runs the complete PPX lifecycle and reports failures at the original marker. |
| `subtractor/hamlet_subtractor_resolver.ml` | Entry point of the isolated helper process; it runs the server that returns probe evidence. |

The [architecture guide](./architecture.md) shows how these pieces interact.
Resolver discovery and process isolation are described once in the
[integration guide](./integration.md#resolver-process).
