# hamlet-subtractor

`hamlet-subtractor` gives Hamlet exact automatic propagation for errors and
service requirements. It is a staged PPX package: it replaces an automatic
marker with ordinary, type-safe OCaml before Dune, Merlin, or OCaml-LSP
type-check the module. Consequently, hover shows the same precise residual
effect type that a build sees.

```ocaml
Hamlet.Combinators.catch source ~handler:(fun error ->
  match error with
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

The final arm forwards only the certified unhandled leaves. For requirements,
use `[%hamlet.propagate_s.auto]` with `Hamlet.Combinators.provide`; a direct
`Tag.give` arm discharges a requirement and the generated residual uses
`Hamlet.Dispatch.need`.

## Use in a Hamlet project

Hamlet is not published in opam yet. Pin Hamlet, its PPX, and this package from
GitHub together:

```sh
opam pin add --yes --no-action hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes --no-action ppx_hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes hamlet-subtractor \
  "git+https://github.com/hamlet-org/hamlet-subtractor.git#automatic-propagation-subtractor"
```

`hamlet-subtractor.opam` records the two Hamlet Git pins too, so a future opam
installation of this package obtains the same source dependencies
automatically. A local checkout can instead run `make setup`; it uses the
same URL and lets maintainers override `HAMLET_GIT_URL` and `HAMLET_GIT_REF`.

Then configure each Dune target that contains an automatic marker with the
staged bundle:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The bundle includes `ppx_hamlet`, so do not list `ppx_hamlet` separately in
that target. No editor plugin, daemon, source rewrite, or resolver command is
needed. Merlin and OCaml-LSP receive the same final PPX AST as Dune, including
for unsaved text in the active buffer.

Use `staged_pps` for every target with `propagate_e.auto` or
`propagate_s.auto`; ordinary `(pps hamlet-subtractor.ppx)` is rejected for
those markers. Targets that only need Hamlet declarations can continue to use
`(pps ppx_hamlet)`. [Automatic Propagation](docs/automatic-propagation.md)
explains why the staged form is required.

When a finite exact input row cannot be demonstrated, compilation points to
the marker and asks for the established explicit boundary:

```ocaml
[%hamlet.te Storage]
[%hamlet.ts Logger.Tag.r, Clock.Tag.r]
```

This is a soundness boundary, not a wider automatic fallback. See
[Automatic Propagation](docs/automatic-propagation.md) for supported forms,
examples, diagnostics, and the explicit fallback.

## Compatibility

The resolver uses OCaml compiler Typedtree APIs, so each release targets one
exact OCaml patch and a matching Hamlet/`ppx_hamlet` pair. The current target is
OCaml 5.5.0. See [Automatic Propagation](docs/automatic-propagation.md) for the
full compatibility and staged-elaboration model.

## Repository development

The repository contains the complete automatic-propagation suite, including
unit and PPX tests, staged Dune fixtures, raw Merlin and OCaml-LSP hover
checks, and a clean installed-consumer project. The main entry points are:

```sh
make test
make installed-consumer
make installed-consumer-keep
make all
```

`make installed-consumer-keep` preserves its temporary isolated project and
prints its location for manual editor inspection. The normal target removes
that temporary project after the test.

Maintainers should start with [Subtractor Internals](docs/README.md).
It explains the probe, compiler evidence, proof model, resolver protocol,
generation, integration, and test layers.

## License and issues

`hamlet-subtractor` is released under the MIT license. Report issues at
<https://github.com/hamlet-org/hamlet-subtractor/issues>.
