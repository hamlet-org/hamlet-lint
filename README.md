# hamlet-subtractor

`hamlet-subtractor` implements exact automatic propagation for Hamlet errors
and service requirements.

A Hamlet computation has this type:

```ocaml
('value, 'errors, 'requirements) Hamlet.t
```

When a `catch` handles only some errors, the subtractor generates the cases
that forward the remaining errors. When a `provide` supplies only some
services, it generates the cases that request the remaining services.

```ocaml
Hamlet.Combinators.catch source ~handler:(fun error ->
  match error with
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

The generated code is ordinary OCaml. Dune, Merlin, and OCaml-LSP type-check
that code, so editor hovers show the same precise type as the build.

## Installation

Hamlet is not published in opam yet. Pin Hamlet, its PPX, and the subtractor:

```sh
opam pin add --yes --no-action hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes --no-action ppx_hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes hamlet-subtractor \
  "git+https://github.com/hamlet-org/hamlet-subtractor.git#main"
```

Use the staged PPX in every Dune target that contains an automatic marker:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The bundle already includes `ppx_hamlet`; do not list it again in the same
target. Nothing else needs to be started or configured.

`staged_pps` matters because the subtractor must read the compiled interfaces
of imported modules before it can prove which effects exist. Ordinary `pps`
may run before those interfaces have been built. The
[usage guide](docs/automatic-propagation.md) explains this boundary in detail.

## Markers and fallback

- `[%hamlet.propagate_e.auto]` forwards unhandled errors from `catch`.
- `[%hamlet.propagate_s.auto]` forwards unsupplied services from `provide`.

If the subtractor cannot prove the complete input row, compilation stops at
the marker. Add an explicit universe and use the non-automatic marker:

```ocaml
[%hamlet.te Storage]
[%hamlet.ts Logger.Tag.r, Clock.Tag.r]
```

This refusal prevents the PPX from silently dropping a possible effect.

## Documentation

- [Automatic Propagation](docs/automatic-propagation.md): setup, supported
  code, examples, and fallbacks.
- [Architecture](docs/architecture.md): the PPX, probe, resolver, and generated
  AST.
- [Proof Model](docs/proof-model.md): what counts as exact evidence and why
  some programs are refused.
- [Compiler and Editor Integration](docs/integration.md): Dune phases, Merlin,
  resolver transport, and diagnostics.

## Development

```sh
make setup
make test
make installed-consumer
make all
```

`make installed-consumer-keep` preserves the temporary consumer project for
manual editor inspection. Dune-backed commands should run serially in this
repository.

The current release targets OCaml 5.5.0 and Dune 3.18 or newer. The resolver
uses version-specific OCaml compiler APIs, so each release is paired with an
exact OCaml version and matching Hamlet packages.

The project is licensed under MIT. Report issues at
<https://github.com/hamlet-org/hamlet-subtractor/issues>.
