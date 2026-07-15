# Automatic Propagation

Hamlet effects have three type parameters:

```ocaml
('value, 'errors, 'requirements) Hamlet.t
```

`'errors` records the failures that may be raised. `'requirements` records the
services that must still be provided. Automatic propagation lets a handler
deal with selected entries and forward the rest without manually listing the
complete input row.

The two markers are:

```ocaml
[%hamlet.propagate_e.auto]
[%hamlet.propagate_s.auto]
```

`e` means errors. `s` means services or requirements. `propagate_s.auto` is the
only requirement spelling. There is no separate `propagate_r.auto` behavior.

## Overview

The subtractor is the compilation step that replaces an automatic marker with
ordinary, typed OCaml propagation code. It proves the finite input row at the
handler, removes the entries handled by complete preceding arms, and emits the
exact residual handler before the normal compiler or Merlin types the module.

This gives the feature three important properties:

1. Merlin hover shows the final narrow effect type, including unsaved changes
   in the current buffer, within the supported compiler configuration.
2. Dune and Merlin type the same final expansion.
3. If Hamlet cannot prove an exact finite row, compilation fails at the marker
   and asks for an explicit `%hamlet.te` or `%hamlet.ts` annotation. Hamlet does
   not guess or silently widen the result.

There is no runtime reflection, editor plugin, linter command, or
linter-and-rewrite step. The generated code uses the existing typed
`Hamlet.Combinators.fail`, `Hamlet.Dispatch.need`, and `Errors.Cases` APIs.
The historical `hamlet-lint` project supplied the original Typedtree analysis;
its packages and commands are historical and are not part of this workflow.

## Project setup

Hamlet is not published in opam yet. Pin it, its PPX, and Hamlet Subtractor
from GitHub before configuring Dune:

```sh
opam pin add --yes --no-action hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes --no-action ppx_hamlet \
  "git+https://github.com/hamlet-org/hamlet.git#main"
opam pin add --yes hamlet-subtractor \
  "git+https://github.com/hamlet-org/hamlet-subtractor.git#automatic-propagation-subtractor"
```

The subtractor package records the two Hamlet Git pins as opam metadata too,
so an opam installation can fetch its source dependencies without a manually
managed checkout. `hamlet-subtractor` is tied to a specific OCaml
compiler-libs generation. Compatibility begins at OCaml 5.5.0, and the current
matrix contains 5.5.0. Dune 3.18 or newer is required. This repository tests
the editor path with Merlin 5.7 for OCaml 5.5.0 and OCaml-LSP 1.26.

Every Dune stanza containing an automatic marker must use the staged Hamlet
rewriter:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The same form works for an `executable` or `test` stanza.
`hamlet-subtractor.ppx` includes the normal `ppx_hamlet` transformations, so do not
add a second `ppx_hamlet` entry to the same preprocessing field.

That stanza is the complete setup for a repository consuming an installed
release. In this repository's uninstalled checkout, the raw Merlin fixture
also declares:

```lisp
(preprocessor_deps
 (package hamlet-subtractor))
```

This repository-only edge builds the local resolver before a raw editor query.
The PPX then derives the resolver beside its own `.ppx` build directory in the
same Dune build context. Installed projects use the resolver from the
`hamlet-subtractor` Dune site and must not copy this source-tree stanza.

The ordinary `(pps hamlet-subtractor.ppx)` form is intentionally unsupported for
automatic markers. It can run before dependency interfaces exist and therefore
cannot prove cross-module rows. Hamlet reports this configuration at the
marker instead of producing an imprecise fallback.

Modules that only declare services and never use an automatic marker may keep
using the regular rewriter:

```lisp
(preprocess
 (pps ppx_hamlet))
```

Standard Dune-generated Merlin configuration is sufficient. Dune builds the
required dependency interfaces automatically, including on a clean build. An
unsaved edit in the active module is visible immediately. An unsaved edit in a
different module is represented by that module's last built interface until
Dune rebuilds it.

Do not enable Merlin's optional external PPX result cache. It does not include
dependency interfaces in its cache key and can therefore skip required
elaboration. Standard Dune-generated configuration leaves this cache disabled.

If a target combines Hamlet with another whole-file PPX that rewrites the
upstream effect or handler, that transform must run before Hamlet elaboration.
A later transform that changes already elaborated handlers is unsupported.

Automatic propagation supports the compilation modes carried by OCaml's
standard PPX context and the normal defaults for modes that context omits.
Unusual nondefault compiler modes that are invisible to an ordinary PPX are
outside this guarantee. Examples include `-nopervasives`, `-no-std-include`,
`-app-funct`, and nondefault strict sequence or format modes. Use an explicit
`%hamlet.te` or `%hamlet.ts` boundary in targets that enable such modes unless
the Hamlet release notes list the combination as supported. The final compiler
still type-checks generated code, but the subtractor cannot claim identical
probe context for an option it never receives.

## Automatically propagating errors

Use `propagate_e.auto` as the final arm of an inline
`Hamlet.Combinators.catch` handler:

```ocaml
let recovered =
  Hamlet.Combinators.catch storage_program
    ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error as error -> recover error
      | [%hamlet.propagate_e.auto] -> .)
```

If `storage_program` can fail with `read_error`, `write_error`, and
`network_error`, the first arm removes `read_error`. The generated final arm
forwards `write_error` and `network_error` with
`Hamlet.Combinators.fail`.

Errors introduced by recovery remain in the result:

```ocaml
let recovered =
  Hamlet.Combinators.catch storage_program
    ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error ->
          Hamlet.Combinators.fail `Recovery_failed
      | [%hamlet.propagate_e.auto] -> .)
```

The final error row contains `Recovery_failed` together with every residual
error from `storage_program`. Recovery computations may also introduce service
requirements, which remain in the third type parameter as usual.

The current marker remains type-safe even when the recovery computation is too
indirect for Hamlet to analyze: the recovery branch is left unchanged and the
final OCaml type check infers it normally. In that case both channels of its
internal certificate become opaque, so a later automatic marker that depends
on this result requires an explicit boundary. Direct canonical `success`,
`return`, `fail`, generated `Tag.summon`, and other supported traced concrete
computations retain exact certificates for dependent markers.

An error arm subtracts a leaf only when it is an unguarded complete pattern:

```ocaml
| #Storage.Errors.read_error -> recover ()
| #Storage.Errors.read_error as error -> recover error
```

A guarded arm may decline a matching value, so it does not subtract that leaf:

```ocaml
| #Storage.Errors.read_error as error when retryable error -> recover error
```

If the guard is false, the automatic arm still propagates `read_error`.

## Automatically propagating requirements

Use `propagate_s.auto` as the final arm of an inline
`Hamlet.Combinators.provide` handler:

```ocaml
let with_logger =
  Hamlet.Combinators.provide
    ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    program
```

If `program` requires `Logger`, `Clock`, and `Database`, the `Tag.give` arm
discharges `Logger`. The generated final arm forwards `Clock` and `Database`
with `Hamlet.Dispatch.need`.

An explicit arm that calls `Dispatch.need` forwards its service rather than
discharging it, so that service remains in the final requirement row. Both
`Tag.give` and `Dispatch.need` must be direct resolved calls using the witness
bound by that same pattern. Indirect helper calls require the explicit
fallback.

Errors are not subtracted by `provide`: the program's error row remains
intact, including errors produced when the supplied implementation runs.

As with errors, a guarded `Tag.give` arm does not subtract its service because
the guard may fail.

## Supported handler shape

Automatic elaboration deliberately supports a narrow, predictable shape:

- a direct `Combinators.catch` or `Combinators.provide` call, including the
  `Hamlet.Combinators` qualified form and the normal pipeline form;
- an inline `fun` or `function` handler;
- a finite, materializable input row obtained from a supported exact origin;
- complete `#Path` error arms and direct `#Service.Tag.r as witness` service
  arms;
- an automatic marker as the final arm with `.` as its body.

Supported exact origins include an external value description, a direct
canonical `success`, `return`, `fail`, or generated `Tag.summon`, an immutable
alias of an already proven effect value, an explicit occurrence boundary, and
the output of an earlier resolved marker. Within the supported compiler
configuration, an independently generalized value with one unconstrained
generic row tail is accepted only when Hamlet can close a fresh copy to its
visible leaves without constraining the surrounding program. This includes a
bare generic channel proven to be empty. Use an explicit boundary when a
target relies on a nondefault compiler mode that the standard PPX context does
not carry.

### Inferred concrete sources and local builders

An annotation is not required just because a concrete local source was built
with Hamlet combinators. For example, this source is inferred from its direct,
recognized `Tag.summon` and `let*` composition:

```ocaml
let requirement_source =
  let open Hamlet.Combinators in
  let* (_ : Logger.Tag.t) = Logger.Tag.summon in
  let* (_ : Clock.Tag.t) = Clock.Tag.summon in
  return "ready"

let with_logger =
  Hamlet.Combinators.provide requirement_source
    ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
```

The generated result still requires `Clock`, without a hand-written
`[%hamlet.ts Logger, Clock]`. A directly applied local builder is accepted on
the same basis:

```ocaml
let build_requirement_source () =
  let open Hamlet.Combinators in
  let* (_ : Logger.Tag.t) = Logger.Tag.summon in
  let* (_ : Clock.Tag.t) = Clock.Tag.summon in
  return "ready"

let with_logger =
  Hamlet.Combinators.provide (build_requirement_source ())
    ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
```

This is deliberately a proof of a concrete source, not a general row-difference
operator. The resolver accepts only recognized direct Hamlet calls and binding
operators, and every relevant builder branch must itself have an independent
origin. It identifies those calls by resolved UID, never by their printed name.
For a local builder application, the builder must be an independently
generalized local function applied directly with positional arguments, and the
selected error or requirement channel of its result must share no type variable
with any applied argument. A unit builder is the usual case.

This does not make a parameterized helper automatically polymorphic in its
caller's row. In particular, a function whose effect row depends on a parameter,
or whose source comes through a higher-order callback, mutable state, object,
first-class module, indirect combinator alias, or unrecognized composition
still requires the explicit `%hamlet.te` or `%hamlet.ts` boundary. A marker in a
generic helper body is elaborated when that body is compiled, not again for each
caller or downstream compilation unit.

Transparent public type aliases may be expanded. Abstract, private, or hidden
aliases are not treated as evidence. Aliases of combinator functions and
unrecognized or higher-order producer flows are outside the exact origin tracer
and use the explicit fallback.

When every input leaf has already been handled, OCaml warning 11 remains
visible. Remove the redundant automatic marker instead of suppressing the
warning unless the test intentionally covers the exhausted case.

Hamlet reports an actionable refusal for shapes whose exact meaning cannot be
proved. Common examples include:

- abstract or hidden row aliases;
- genuinely open rows, context-only rows, or rows rooted in a function
  parameter;
- named, higher-order, or otherwise indirect handlers;
- wildcard, or-pattern, partial payload, or unsupported control-flow arms;
- grouped requirement aliases containing more than one service tag;
- a marker that is not last.

This boundary is intentional. Automatic elaboration may reject a program, but
it may not invent runtime reachability.

## Explicit fallback

Use the existing explicit syntax whenever automatic elaboration refuses the
input or when an explicit API boundary is clearer.

For errors, declare the universe with `%hamlet.te` and use the ordinary
propagation marker:

```ocaml
Hamlet.Combinators.catch source
  ~handler:(fun
    (error :
      [%hamlet.te
        Storage.Errors.read_error, Storage.Errors.write_error]) ->
    match error with
    | #Storage.Errors.read_error -> recover ()
    | [%hamlet.propagate_e] -> .)
```

A whole generated service universe can be written as
`[%hamlet.te Storage]`.

For requirements, use `%hamlet.ts`:

```ocaml
Hamlet.Combinators.provide
  ~handler:(fun (requirement : [%hamlet.ts Logger, Clock]) ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s] -> .)
  source
```

The explicit annotation is the precision boundary chosen by the author. It is
also the correct choice for public polymorphic functions whose callers may
supply rows that are not finite at the definition site.

## Services across compilation units

For a generated service whose error catalogue will be consumed from another
compilation unit, expose the cross-unit propagation catalogue:

```ocaml
[%%hamlet.service
module type Storage = sig
  type read_error = [ `Read_error of string ]
  type write_error = [ `Write_error of string ]

  val read :
    string -> (string, [> read_error | write_error ], 'r) Hamlet.t
end
[@@rest_cross_cu]]
```

This keeps downstream full-universe error propagation linear in the number of
declared leaves. It is required when an automatic handler consumes an external
generated error union. Hamlet first validates that `Errors.Cases` is a complete,
non-overlapping partition and maps every structural atom uniquely to that
catalogue. A certified proper subset is then emitted directly from its named
leaves, while the complete universe uses `Cases.dispatch`. An external
`%%hamlet.errors` union without the cross-unit protocol uses an explicit
`%hamlet.te` fallback even when the observed residual appears smaller.
Requirement tags need no additional opt-in.

A producer module can use ordinary `pps ppx_hamlet`. The consumer module that
contains an automatic marker must use `staged_pps hamlet-subtractor.ppx`.
Using the staged bundle consistently for an entire application target is
usually the simplest configuration.

## Testing in this repository

The focused tests live in `test/automatic_propagation` and exercise the public
Hamlet and Dune interfaces from the uninstalled checkout. The positive
raw-Merlin fixture has
the repository-only `preprocessor_deps` edge described above so the resolver
exists before the editor starts. `make installed-consumer` separately proves
that external projects need only the documented `staged_pps` stanza.

The active opam switch must provide `ocamlmerlin` and `ocamllsp` for the editor
harnesses.

```sh
dune runtest test/automatic_propagation
```

This runs the complete acceptance gate: final CMT type and runtime behavior,
saved and unsaved OCaml-LSP hovers, raw Merlin final preprocessing and
Typedtree checks, dependency-CMI invalidation, refusal diagnostics, explicit
fallbacks, and linear cross-unit generation. The mutable checks use a separate
acceptance build directory while raw Merlin keeps the normal Dune editor
context.

```sh
dune build @test/automatic_propagation/automatic-propagation-lsp
```

This starts a real installed OCaml-LSP session and verifies saved and unsaved
hover types, diagnostics, and clean shutdown.

```sh
dune build @test/automatic_propagation/automatic-propagation-acceptance
```

This is an explicit name for the same complete acceptance gate.

```sh
test/automatic_propagation/run_acceptance.sh
```

This runs the same complete feature harness directly. It rejects embedded PPX
errors, probe assertions, and internal marker attributes before accepting an
editor result. The script temporarily changes its dependency fixture and
restores it on exit.

```sh
make installed-consumer
```

This installs matching Hamlet and subtractor packages into a fresh temporary
prefix, builds and runs a separate project whose only preprocessing entry is
`(staged_pps hamlet-subtractor.ppx)`, confirms that the prefix-relative
resolver was used, and checks narrow raw Merlin hovers. Its requirement source
intentionally uses an inferred `let*` composition of generated `Tag.summon`
calls rather than a closed annotation, while its error source is an
unannotated direct `Combinators.fail` value. It protects the installed-project
setup from accidentally depending on source-tree Dune metadata or
annotation-only coverage.

Run the repository-wide gate after the focused checks:

```sh
make all
```

When adding coverage:

- add compile-positive `case_*` bindings to
  `test/automatic_propagation/automatic_propagation_positive.ml`;
- add runtime behavior to
  `test/automatic_propagation/automatic_propagation_runtime_test.ml`;
- add unsupported programs under `test/automatic_propagation/negative` and
  record their required diagnostic fragments in
  `automatic_propagation_diagnostics.expected`;
- put cross-unit producer declarations in `automatic_propagation_external.ml`.

Run Dune-backed checks serially. The feature harness already covers multiple
compiler and editor entry points, so overlapping Dune processes only add noise
and can leave stale build locks.

## Testing in a consuming repository

At minimum, keep three kinds of coverage:

1. A compile-positive module or `.mli` that fixes the expected narrow error and
   requirement rows.
2. A runtime test proving handled leaves are recovered or discharged and
   residual leaves still propagate.
3. A negative compile test for any project-specific abstract or polymorphic
   boundary that must keep the explicit `%hamlet.te` or `%hamlet.ts` fallback.

Editor hover requires no separate project test or plugin. If a repository
needs to lock that behavior for its own toolchain, use an OCaml-LSP session
against a saved buffer and an unsaved `didChange`, following
`test/automatic_propagation/automatic_propagation_lsp_client.ml` in this
repository.

## Related guides

- [Hamlet Services](https://github.com/hamlet-org/hamlet/blob/main/docs/services.md)
  explains service declarations, tags, and implementations.
- [Hamlet Error Propagation](https://github.com/hamlet-org/hamlet/blob/main/docs/error-propagation.md)
  explains the generated linear catalogue used at cross-unit boundaries.
- [Subtractor Internals](../subtractor/docs/README.md) explains the probe,
  proof model, compiler integration, and final AST generation for maintainers.
