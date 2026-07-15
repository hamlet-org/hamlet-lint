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

Install Hamlet and the matching Subtractor package from opam:

```sh
opam install hamlet hamlet-subtractor
```

The package selected for your exact OCaml compiler requires the same exact
Hamlet and `ppx_hamlet` version. A local Subtractor checkout can run
`make setup`; it installs those dependencies from opam too.

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

The resolver reads OCaml compiler Typedtree APIs. Each published package
targets one exact OCaml patch and requires the matching exact `hamlet` and
`ppx_hamlet` opam version. Compatibility starts at OCaml 5.5.0. The current
release family is Hamlet 0.1.0 on OCaml 5.5.0; later compiler patches require
an explicit compatibility layer and matching CI image.

The release policy has two source files. `release/current-hamlet.sh` selects
the one supported Hamlet release tag. `release/versions.sh` lists supported
OCaml patches. A release creates the Cartesian product of those two values,
skips packages already published or in an open upstream PR, and cannot accept
a caller-selected Hamlet version, branch, commit, or OCaml matrix. The tag is
resolved to a commit for release provenance; installed packages use ordinary
exact opam constraints instead of Git pins.

When Hamlet releases 0.2.0, update `release/current-hamlet.sh` and dispatch a
release to publish 0.2.0 for every currently supported OCaml patch. When a new
OCaml patch is supported, add it only to `release/versions.sh`; the dispatcher
publishes it only for the configured current Hamlet release. Existing package
versions remain historical and are never backfilled.

Development CI may still read Hamlet `main` with `HAMLET_READ_TOKEN` so it can
detect upcoming compatibility changes. That credential is not used by the
release workflow or by installed users.

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
