# Documentation

- [Automatic Propagation](./automatic-propagation.md) explains setup, ordinary
  markers, generic helpers, composition, and explicit fallbacks.
- [Supported Patterns](./supported-patterns.md) contains small accepted
  examples and their resulting rows.
- [Refused Patterns](./refused-patterns.md) shows unsafe or ambiguous forms and
  how to make each boundary explicit.
- [Architecture](./architecture.md) follows source code through the probe,
  resolver, proof engine, and final generated AST.
- [Proof Model](./proof-model.md) defines exact evidence, declaration identity,
  and subtraction.
- [Compiler and Editor Integration](./integration.md) explains `staged_pps`,
  dependency interfaces, the resolver process, Merlin, and packaging.

The short version: the PPX creates a temporary analysis copy of the module,
asks an isolated OCaml type checker for exact effect evidence, and inserts
ordinary forwarding cases into the original AST. The temporary copy is never
compiled as the user's program. If the evidence is incomplete, the PPX stops
instead of guessing.
