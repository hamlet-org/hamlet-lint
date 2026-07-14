# hamlet-subtractor

`hamlet-subtractor` gives Hamlet exact automatic propagation for errors and
service requirements. It is a staged PPX package, not a command-line linter:
it replaces an automatic marker with ordinary, type-safe OCaml before Dune,
Merlin, or OCaml-LSP type-check the module. Consequently, hover shows the
same precise residual effect type that a build sees.

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
  "git+https://github.com/hamlet-org/hamlet.git#automatic-propagation-elaboration"
opam pin add --yes --no-action ppx_hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#automatic-propagation-elaboration"
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

The ordinary `(pps hamlet-subtractor.ppx)` form is deliberately unsupported
for automatic markers. Use `staged_pps`: it gives the resolver the dependency
interfaces required to prove a cross-compilation-unit row.

When a finite exact input row cannot be demonstrated, compilation points to
the marker and asks for the established explicit boundary:

```ocaml
[%hamlet.te Storage]
[%hamlet.ts Logger.Tag.r, Clock.Tag.r]
```

This is a soundness boundary, not a wider automatic fallback. See
[Automatic Propagation](docs/automatic-propagation.md) for supported forms,
examples, diagnostics, and the explicit fallback.

## Compatibility and releases

The resolver reads OCaml compiler Typedtree APIs. Each package targets one
exact OCaml patch and pins `hamlet` with `ppx_hamlet` from one immutable
GitHub commit. Development uses the current branch, but the release dispatcher
resolves that branch once and rejects any non-commit release input before it
generates opam metadata. Compatibility starts at OCaml 5.5.0. The current
matrix contains OCaml 5.5.0; support for later compiler patches is added with
an explicit compatibility layer and matching CI image.

Maintainer release runs need read access to the private companion repository.
Set the optional `HAMLET_READ_TOKEN` GitHub Actions secret with repository
contents read access, or grant the subtractor workflow token the same access.
The credential is used only for the CI Git transport and never appears in the
generated opam metadata.

There is one forward-moving source tree. While Hamlet is installed from Git,
the paired pins ensure the resolver is never combined with an unrelated Hamlet
PPX or compiler version. When Hamlet is published in opam, the pins can become
ordinary exact package constraints without changing the Dune setup.

`hamlet-lint` is the repository and package lineage from which the Typedtree
analysis was migrated. Its old packages and releases remain historical. This
repository does not install, document, or expose `hamlet-lint` or
`hamlet-lint-extract` commands.

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

Maintainers should start with [Subtractor Internals](subtractor/docs/README.md).
It explains the probe, compiler evidence, proof model, resolver protocol,
generation, integration, and test layers.

## License and issues

`hamlet-subtractor` is released under the MIT license. Report issues at
<https://github.com/hamlet-org/hamlet-subtractor/issues>.
