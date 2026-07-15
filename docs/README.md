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
[Automatic Propagation](./automatic-propagation.md) instead.

## What happens to one marker

For an automatic marker, the PPX keeps the user's program as the **base AST**
and creates a second, temporary **probe AST**. In the probe, the marker becomes
a safe synthetic branch that lets the resolver ask the OCaml type checker what
the upstream effect actually is. The resolver types that probe once in its own
isolated compiler-libs session and returns a proof of the exact residual row,
or a refusal.

The probe is analysis-only: it is never emitted as the user's program. With a
proof, the PPX replaces the marker in the base AST with ordinary forwarding
code and removes every internal marker attribute. Dune, Merlin, and OCaml-LSP
then type that final expansion normally. This second type check is the one that
accepts or rejects the user's module, so the resolver cannot bypass OCaml's
normal checks.

## Reading the code

The implementation follows that flow:

- `subtractor/core` defines the small, compiler-independent language of exact
  effect proofs: leaves, rows, residuals, certificates, and the algorithms that
  combine them. It has no dependency on OCaml's Typedtree representation.
- `subtractor/hamlet_subtractor_probe.ml` finds supported automatic markers,
  identifies their owning `catch` or `provide` call, and builds the base/probe
  AST pair with stable links between them.
- `subtractor/hamlet_subtractor_compiler_evidence.ml` reads the Typedtree of
  the probe. It verifies that calls and service tags are the real Hamlet ones,
  then turns those facts into an immutable exact proof instead of inferring a
  row from surface syntax.
- `subtractor/hamlet_subtractor_engine.ml` applies that proof to the user's
  preceding handler arms, computes what remains to forward, and orders markers
  that depend on another marker in the same module.
- `subtractor/hamlet_subtractor_generator.ml` and
  `subtractor/hamlet_subtractor_replace.ml` turn the engine result into normal
  OCaml cases and constraints, then splice them into the base AST.
- `subtractor/hamlet_subtractor_ppx.ml` orchestrates the whole lifecycle:
  ordinary Hamlet rewriting, probe creation, resolver invocation, diagnostics,
  and final replacement.
- `subtractor/hamlet_subtractor_resolver.ml` is the resolver process entry
  point. The server behind it receives the prepared probe, types it in isolation,
  and returns the proof through the shared protocol.

## How the PPX finds the resolver

Consumers never run the resolver themselves. The PPX starts the matching
resolver executable when it needs exact evidence.

For an installed package, Dune records the resolver's installation directory in
the `hamlet-subtractor` package site, so the PPX obtains a path to the resolver
that was installed with the same package version. In this source checkout, the
test fixture instead makes the resolver an explicit build dependency and derives
its path beside the running `.ppx` executable. Both routes keep the PPX and
resolver in the same build/install context and deliberately avoid searching
`PATH`, which could select an unrelated executable.
