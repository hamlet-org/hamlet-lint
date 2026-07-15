# hamlet-subtractor

`hamlet-subtractor` generates exact forwarding cases for Hamlet errors and
service requirements.

```ocaml
Hamlet.Combinators.catch source ~handler:(fun error ->
  match error with
  | #Storage.Errors.read_error -> recover error
  | [%hamlet.propagate_e.auto] -> .)
```

The PPX reads the input computation's inferred effect rows, subtracts the
preceding handler arms, and replaces the marker with ordinary OCaml cases. It
refuses the marker if the complete input row cannot be proved. The normal
compiler, Merlin, and OCaml-LSP type-check the generated code.

## Install

Hamlet is not published in opam yet. Pin Hamlet, its PPX, and this package:

```sh
opam pin add --yes --no-action hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes --no-action ppx_hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes hamlet-subtractor \
  "git+https://github.com/hamlet-org/hamlet-subtractor.git#main"
```

Use the staged PPX in each target that contains automatic propagation, defines
a generic helper, or calls one:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The bundle already includes `ppx_hamlet`. Do not list it again in the same
target. Targets that use no subtractor feature may keep ordinary
`(pps ppx_hamlet)`.

## Use

- `[%hamlet.propagate_e.auto]` forwards errors not handled by a `catch`.
- `[%hamlet.propagate_s.auto]` forwards services not supplied by a `provide`.
- `let[@hamlet.generic]` makes a reusable helper specialize automatically when
  called directly with a concrete effect.

One marker is enough. Multiple markers may form a supported linear sequence of
Hamlet operations. When a row is open or hidden, declare an explicit universe
with `%hamlet.te` or `%hamlet.ts` and use the corresponding non-automatic
marker.

Start with [Automatic Propagation](docs/automatic-propagation.md). The
[supported](docs/supported-patterns.md) and
[refused](docs/refused-patterns.md) example guides show the exact boundary.
The [documentation index](docs/README.md) links the architecture, proof, and
compiler-integration references.

## Develop

```sh
make setup
make test
make installed-consumer
make all
```

`make installed-consumer-keep` preserves the generated consumer project for
manual editor inspection. Run Dune-backed commands serially in this checkout.

The current release targets OCaml 5.5.0 and Dune 3.18 or newer. The project is
licensed under MIT.
