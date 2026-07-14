# Compiler and Editor Integration

Automatic propagation is delivered as a normal staged PPX. Dune, the OCaml
compiler, Merlin, and OCaml-LSP do not need Hamlet-specific changes. The
important integration rule is that the PPX must resolve every automatic marker
before returning its AST.

The public setup is:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

`hamlet-subtractor.ppx` bundles the ordinary `ppx_hamlet` transformations with
the subtractor. A target must not list `ppx_hamlet` separately.

That is the entire preprocessing setup for a project using an installed
release. This repository adds a `preprocessor_deps` package edge only to the
uninstalled raw-Merlin fixture so Dune builds the local resolver before the
editor query. Installed consumers deliberately omit that source-tree edge.

For application-level usage, see
[Automatic Propagation](../../docs/automatic-propagation.md). This document
explains what happens inside the preprocessing process and how the compiler and
editor paths stay equivalent.

## Why staged preprocessing is required

Dune invokes a staged PPX in more than one compilation phase. The relevant
phases have different capabilities:

- Dependency discovery: dependency CMIs are not guaranteed. Preserve ordinary
  dependencies, lower markers to a type-safe bottom branch, and do not type the
  module.
- Compiler preprocessing: dependency CMIs are available. Build and type the
  probe, resolve every marker, and return the final expansion.
- Merlin preprocessing: built dependency CMIs are available. Use the current
  live buffer, resolve every marker, and return the same final expansion shape.

An ordinary `(pps hamlet-subtractor.ppx)` pipeline may preprocess the implementation
before Dune has built the interfaces needed to prove cross-unit catalogues. The
rewriter refuses automatic markers in that mode and reports the required
`staged_pps` configuration.

The dependency-discovery output is not a widened implementation of automatic
propagation. It is a temporary dependency-safe AST used only to let Dune learn
which modules must be built. The compiler and Merlin phases must resolve the
markers again from their own current input.

## One PPX lifecycle

The combined driver performs these steps in one invocation:

1. Read the standard PPX context attached by the caller.
2. Run normal Hamlet declaration and explicit propagation rewriting.
3. Discover automatic markers and validate their supported Parsetree shape.
4. Build a canonical base structure and a temporary probe structure.
5. Serialize the live probe AST and supported compiler context to the selected
   lockstep resolver process.
6. Type the probe in an isolated compiler-libs session.
7. Convert Typedtree facts into compiler-independent proofs and catalogues.
8. Validate the correlated response and resolve dependencies between markers.
9. Generate exact residual cases and complete owner-result constraints.
10. Strip every internal attribute and return ordinary OCaml Parsetree.

The final compiler invocation does not reuse the temporary Typedtree. It types
the returned structure normally. This second type check is authoritative and
catches any mismatch between the evidence resolver and generated OCaml.

## Compiler context

Probe typing must describe the same compilation unit as the final type check.
The integration layer snapshots the supported context before entering
compiler-libs and restores it inside an isolated compiler store.

The snapshot combines the active source filename from the PPX driver with the
fields exposed by OCaml 5.5's standard PPX context:

- tool identity;
- visible and hidden include directories and load paths;
- opened modules;
- `for_package` wrapping identity;
- debug, thread, recursive-type, principal, alias-dependency, and unboxed-type
  modes;
- PPX cookies;
- the current OCaml, protocol, subtractor PPX, expected resolver, and AST
  versions added by the subtractor itself.

Fields used only to correlate a request with its response are kept separate
from the semantic digest. The semantic digest must be equal when `ocamlc`,
`ocamlopt`, and Merlin describe the same program. It includes only facts that
can change name resolution, typing, catalogues, or generated code.

The protocol does not expose every OCaml command-line mode. Examples omitted
by OCaml 5.5 include `-nopervasives`, `-no-std-include`, applicative-functor
selection, strict sequence and format modes, classic mode, and native-code
selection. Automatic propagation supports their normal defaults. A target
using a nondefault omitted mode must use an explicit `%hamlet.te` or
`%hamlet.ts` boundary unless that combination is separately documented and
tested. An ordinary PPX cannot detect or reconstruct information its caller
does not transmit.

Warnings and delayed checks are suppressed during the temporary probe. The
compiler reports them once while typing the final expansion. Compiler state is
reset after the probe so environment mutations, warning state, delayed checks,
and type variables cannot leak into the caller.

## Inferred concrete sources

Automatic propagation can prove an unannotated local source when its typed
construction is in the audited provenance domain. The resolver follows real
Hamlet UIDs through direct primitives, generated `Tag.summon`, selected direct
combinators, binding operators, and all possible results of supported local
control flow. It then applies the normal fresh principal-scheme closing check.
It never treats the printed visible tags of an arbitrary expression as a closed
universe.

The same rule covers a directly applied local builder. The builder must be a
locally bound, independently generalized function whose body traces
independently. Its result's target error or requirement channel must be
disjoint from the types of every positional argument already applied. This is
why `build_source ()` can be exact while a function that returns an effect based
on an `error` or `requirement` parameter remains an explicit-boundary case.
For the local-builder rule, labels, optional arguments, indirect applications,
and generic parameter-rooted rows are intentionally outside the domain.

Final replacement adds a ghost constraint at the original upstream occurrence
from the certified input channel, as well as the existing owner-output
constraint. These are ordinary final AST constraints, not a cached Typedtree
claim: the compiler and Merlin both recheck them after elaboration.

## Isolated resolver process

The resolver executable is the normal backend. It isolates the compiler state
used for probe typing from the PPX process that must return the final AST. It
is an implementation detail of `hamlet-subtractor.ppx`: installed-package
users do not invoke it or add it to Dune stanzas.

The PPX and resolver share one normalized request model. The process path must
preserve the already transformed live probe AST and its exact locations. It
must not reread the saved source file, pretty-print and reparse the probe, or
run the PPX pipeline recursively.

The request contains:

- a protocol version plus the subtractor PPX version and expected resolver
  version;
- a unique request correlation value;
- the semantic context snapshot and digest;
- a location-preserving serialized probe Parsetree;
- the original marker IDs, kinds, spans, and owner metadata;
- validated dependency interface fingerprints known to the caller.

The response contains:

- the same request correlation and semantic digest;
- one normalized outcome for every requested marker;
- complete residual and two-channel effect certificates;
- validated catalogues in declaration order;
- marker-local structured diagnostics.

The PPX validates the complete response before modifying the base AST. Missing,
duplicate, unknown, or mismatched marker IDs are fatal. Version, context,
certificate, or catalogue mismatches are also fatal. A partial response is
never combined with local guesses.

Transport uses bounded length-prefixed frames. The client applies input and
output limits, a timeout, stderr capture, exit-status validation, and complete
child cleanup. A crash, timeout, oversized frame, malformed response, or
version mismatch becomes an error at the original marker. It never falls back
to a stale or widened expansion.

Resolver discovery has two ordered, bounded paths:

1. An installed PPX reads the installation-relative resolver directories from
   the `hamlet-subtractor` Dune site.
2. An uninstalled PPX derives candidates from `Sys.executable_name`: it finds
   the enclosing `.ppx` directory and looks only in the sibling `subtractor`
   directory of that same Dune build context.

The second path exists for this source checkout. Its raw-Merlin fixture
declares `(preprocessor_deps (package hamlet-subtractor))` so the derived
resolver is built before the query. Discovery never searches the user's
`PATH`, another build context, or an arbitrary checkout. This keeps installed
projects on one lockstep Hamlet release and prevents an unrelated resolver
from being selected.

The process transport and monotonic deadline implementation support POSIX
systems, including the tested Linux and macOS configurations. Windows is not a
supported automatic-elaboration target in the current package. Explicit
`%hamlet.te` and `%hamlet.ts` propagation remains available there.

The resolver converts all compiler values into compiler-independent rows,
leaves, catalogues, certificates, diagnostics, and source spans before sending
its response. No `Types.type_expr`, `Env.t`, `Typedtree.expression`, or compiler
UID crosses the process boundary. Direct compatibility-layer tests compare the
same normalized evidence used by process integration tests.

## Source locations and diagnostics

Every marker retains its original source span from the live input buffer. The
outer generated case uses that span so errors are associated with the source
construct the programmer wrote. Internal generated patterns, expressions, and
callbacks use derived ghost locations so diagnostics do not pretend that
generated text exists in the source file.

Probe compiler errors are remapped to the nearest original user node. A
marker-specific refusal points directly at the marker and includes the
appropriate explicit fallback:

```text
automatic error propagation requires a finite exact input row;
add [%hamlet.te ...] and use [%hamlet.propagate_e]
```

```text
automatic requirement propagation requires a finite exact input row;
add [%hamlet.ts ...] and use [%hamlet.propagate_s]
```

The diagnostic code distinguishes causes such as an open row, abstract alias,
unsupported arm, unresolved owner, opaque dependency, missing catalogue, or
resolver failure. This is useful for tests and editor clients while the text
remains actionable for a programmer.

## Merlin and unsaved buffers

Merlin obtains the PPX command and flags from Dune. When it asks about a live
unsaved module, it sends that current Parsetree through the same bundle used by
the build. The subtractor resolves that AST directly and Merlin types only the
returned final expansion. Hover therefore contains the narrow residual effect
row immediately.

There are two separate freshness boundaries:

- changes in the active buffer are visible without saving;
- changes in another module become visible after its CMI is rebuilt, because
  the current module can only type against an existing dependency interface.

No persistent elaboration cache is required for correctness. If a cache is
added for performance, its key must include the complete semantic context,
source and marker identity, subtractor and protocol versions, and every
dependency interface fingerprint. A missing or stale entry must trigger fresh
resolution or a transparent diagnostic.

Merlin's optional external PPX result cache is unsupported because it does not
include dependency interface fingerprints in its key and can bypass the
subtractor entirely.

OCaml-LSP delegates typing and hover to Merlin. It therefore needs no Hamlet
plugin. The acceptance harness verifies both a saved document and a
`textDocument/didChange` update whose content has never been written to disk.

## Interaction with other PPXs

The bundle owns normal Hamlet expansion and automatic elaboration as one
ordered unit. A whole-file transformation that changes the upstream effect,
handler, service declarations, or generated catalogue must run before the
evidence probe. A transformation that rewrites an already elaborated handler
afterward is unsupported unless it is proven to preserve the generated
semantics.

The final output contains none of the probe attributes used to correlate the
callee, owner, handler, upstream expression, or marker. This is checked in
golden tests and prevents later PPXs from depending accidentally on Hamlet's
internal protocol.

## Package layout

The implementation ships in lockstep with Hamlet:

```text
hamlet
  runtime effect APIs

ppx_hamlet
  declarations and explicit propagation syntax

hamlet-subtractor
  hamlet-subtractor.ppx
  compiler-independent proof core
  OCaml compiler compatibility layer
  evidence resolver, engine, generator, and replacement pass
  isolated resolver executable
```

The subtractor depends on compiler-libs internals and therefore targets one
exact OCaml patch for each package release. Compatibility begins at OCaml
5.5.0, with 5.5.0 as the current target. The protocol and runtime package
versions are checked exactly. Installing independently versioned Hamlet and
subtractor packages is unsupported.

The former `hamlet-lint` package lineage is not part of the automatic
propagation workflow. Its old releases and commands are historical, and this
project installs no `hamlet-lint` or `hamlet-lint-extract` executable. The
subtractor runs through the normal project PPX and returns the exact AST that
the compiler and editor type.

## Test layers

The implementation is tested at increasing integration depth.

### Core and PPX tests

These cover row normalization, catalogue validation, arm classification,
residual equations, dependency certificates, protocol round trips, generated
AST snapshots, attribute stripping, and refusal diagnostics.

### Dune integration fixtures

Fixtures exercise clean staged builds, cross-unit dependencies, wrapped and
unwrapped libraries, package mode, supported compiler flags, resolver parity,
multiple markers, recovery contributions, and linear `Errors.Cases`
generation.

### Public acceptance harness

From the repository root:

```sh
dune runtest test/automatic_propagation
dune build @test/automatic_propagation/automatic-propagation-lsp
dune build @test/automatic_propagation/automatic-propagation-acceptance
test/automatic_propagation/run_acceptance.sh
make installed-consumer
```

`dune runtest test/automatic_propagation`, the named acceptance alias, and the
direct script all execute the complete gate: final CMT types, runtime behavior,
saved and unsaved OCaml-LSP hovers, final raw Merlin preprocessing, the
Typedtree Merlin actually types, dependency-CMI invalidation, explicit
fallbacks, refusal diagnostics, and linear cross-unit output. The mutable
checks use a separate acceptance build directory so they never compete with
the outer Dune test action. The gate rejects embedded PPX errors, probe
assertions, or retained internal attributes in raw editor output.

Resolver-specific tests compare the direct compatibility layer with the normal
process path at the normalized evidence and final AST boundaries. They also
inject crashes, timeouts, malformed frames, version mismatches, and incomplete
responses.

`make installed-consumer` stages the released package layout into a temporary
prefix and verifies a separate Dune project, runtime behavior, the
installation-relative resolver path, and narrow raw Merlin hovers without any
source-tree `preprocessor_deps` stanza. Its requirement source is deliberately
unannotated and sequences generated `Logger.Tag.summon` and `Clock.Tag.summon`
through `let*`. Its error source is likewise an unannotated direct
`Combinators.fail` value. The test proves that installed-package elaboration
infers both concrete input rows rather than relying on hand-written `%hamlet.te`
or `%hamlet.ts` boundaries.

Run the repository-wide gate afterward:

```sh
make all
```

Dune-backed commands must run serially in this repository.

## Debugging a failure

Start from the phase named by the diagnostic:

1. A configuration refusal usually means the target used `pps` instead of
   `staged_pps`, or the caller did not provide a supported compiler context.
2. An evidence refusal means the row, origin, arm, or catalogue could not be
   proved exact. Confirm that the explicit `%hamlet.te` or `%hamlet.ts`
   fallback compiles before broadening the resolver.
3. A marker dependency refusal means an earlier marker produced an opaque
   channel or the expression tracer could not prove the connecting flow.
4. A resolver transport refusal should reproduce under the forced process
   backend and must never disappear by reusing an old response.
5. A final compiler error after successful evidence resolution indicates a
   mismatch between the proof model and generated OCaml. Treat it as an
   subtractor bug and reduce it to a PPX golden plus compile test.

When adding support for a new syntactic or typed form, extend the proof model
first, add a negative counterexample, then add final-AST and editor tests. A
larger accepted language is useful only when exactness and materialization are
demonstrated end to end.
