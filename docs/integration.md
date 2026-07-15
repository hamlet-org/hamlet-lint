# Compiler and editor integration

Automatic propagation is implemented entirely by
`hamlet-subtractor.ppx`. Dune, the OCaml compiler, Merlin, and OCaml-LSP need no
Hamlet-specific plugin.

For application setup, see [Automatic Propagation](./automatic-propagation.md).
This guide explains how the PPX uses the compiler and why builds and editor
hovers receive the same result.

## One PPX lifecycle

The bundle performs these steps:

1. Run ordinary `ppx_hamlet` rewriting.
2. Find automatic markers and their `catch` or `provide` owners.
3. Keep a base AST and create a temporary probe AST.
4. Send the probe and current compiler context to the resolver process.
5. Receive exact, compiler-independent evidence for every marker.
6. Compute the residual rows and generate forwarding cases.
7. Insert the cases and type constraints into the base AST.
8. Remove internal attributes and return ordinary OCaml syntax.

The caller then type-checks the returned AST normally. The Typedtree created
for the probe is discarded; it is evidence used to generate code, not a
substitute for the final compiler check.

## Why Dune uses two PPX phases

On a clean build, Dune first needs to discover which modules a source file
imports. At that point some imported `.cmi` interfaces do not exist, so the PPX
cannot prove cross-module effects. The `ocamldep` invocation therefore returns
a dependency-safe AST and does not start the resolver.

After Dune builds those interfaces, it invokes the staged PPX from `ocamlc`,
`ocamlopt`, or Merlin. That invocation has enough type information to resolve
every marker and return the final expansion.

This is the reason for `staged_pps`. The public guide gives a concrete
[comparison with `pps`](./automatic-propagation.md#why-staged_pps-is-required).

## Compiler context

The probe must be typed as the same module that the caller will type next. The
PPX therefore sends the resolver the source filename and the compiler settings
available through the standard PPX context, including:

- visible and hidden include directories;
- modules opened by command-line flags;
- package wrapping identity;
- principal, recursive-type, alias-dependency, and unboxed-type modes;
- PPX cookies and the current tool name;
- exact OCaml, AST, protocol, PPX, and resolver versions.

The resolver recreates this context in a fresh compiler store. It suppresses
warnings and delayed checks while typing the temporary probe, because the final
compiler should report them once against the generated program. The temporary
store is then discarded so its environments and mutable type variables cannot
leak back into the PPX.

OCaml 5.5 does not expose every command-line option through the PPX context.
Nondefault values for omitted options, such as `-nopervasives`,
`-no-std-include`, applicative-functor selection, or strict sequence and format
modes, are outside the automatic guarantee. Use an explicit `%hamlet.te` or
`%hamlet.ts` boundary unless that configuration is specifically supported and
tested.

## Resolver process

The resolver is a small executable installed with the PPX. Users never run it
or mention it in a Dune file. The PPX starts it only when a marker needs typed
evidence.

It is a separate process because OCaml's compiler libraries keep mutable global
state. Typing the probe in the PPX process could change environments, warnings,
or type variables that belong to the caller. Process isolation gives the probe
a clean compiler session and destroys all of that state when the resolver
exits.

### How the executable is found

There are two cases:

- **Installed package:** Dune registers the directory where the package's
  resolver was installed. The PPX reads that registered directory and starts
  the executable found there.
- **This source checkout:** the resolver has not been installed. The test PPX
  runs below the same `_build` directory, so it derives the resolver path from
  its own `.ppx` executable and looks in that build context's `subtractor`
  directory. The test fixture declares an explicit build dependency so the
  file exists before Merlin starts.

Both cases select the resolver built or installed with that PPX. The code does
not search `PATH`, because `PATH` could contain a resolver from another
checkout, compiler switch, or package version.

Normal consuming projects use the installed case and need only the documented
`staged_pps` stanza. The source-checkout dependency is part of this repository's
test fixture, not public setup.

### Request and response

The request contains:

- the serialized probe AST with source locations;
- the source filename and supported compiler context;
- marker IDs, kinds, locations, and owner links;
- protocol and component versions;
- fingerprints of dependency interfaces known to the caller.

The resolver types that AST directly. It does not read the saved source file,
pretty-print and reparse the AST, or run the PPX recursively. This preserves
unsaved editor text and exact locations.

The response contains one outcome for every marker:

- an exact error and requirement certificate, or a structured refusal;
- the residual leaves for the marker;
- validated cross-module catalogues;
- the same request identity and context digest.

Before changing the base AST, the PPX checks that the response matches the
current request and contains every marker exactly once. It never combines a
partial response with local guesses.

The transport uses bounded frames, size limits, a timeout, stderr capture, exit
status checks, and child cleanup. A missing executable, crash, timeout,
malformed response, or version mismatch becomes a diagnostic at the original
marker. POSIX systems are supported; the current automatic resolver does not
support Windows.

No compiler object crosses back from the resolver. `Types.type_expr`,
`Env.t`, `Typedtree.expression`, and compiler UIDs are converted to immutable
proof values before the response is sent.

## Source locations and diagnostics

Each marker keeps its location from the current input AST. Generated outer
cases use that location, while internal nodes use ghost locations so errors do
not point to text that the user never wrote.

Probe typing errors are mapped back to the nearest original node. A refusal at
the marker names both the reason and the explicit fallback, for example:

```text
automatic error propagation requires a finite exact input row;
add [%hamlet.te ...] and use [%hamlet.propagate_e]
```

Stable diagnostic categories distinguish open rows, abstract aliases,
unsupported arms, unresolved owners, opaque dependencies, missing catalogues,
and resolver failures. Tests assert categories and useful text rather than
depending on compiler-internal exception strings.

## Merlin and OCaml-LSP

Merlin obtains the PPX command from Dune. For an unsaved active file, it sends
the current in-memory AST through the same bundle used by the build. Merlin
then types only the final expansion returned by the PPX, so hover shows the
residual row immediately.

Suppose the active buffer is `A.ml` and it imports `B`. Merlin sends the PPX
the current in-memory contents of `A.ml`, but information about `B` comes from
`B.cmi`, the interface produced the last time Dune compiled `B`. A change to an
exported type or value in `B` becomes visible while analysing `A.ml` only after
Dune rebuilds `B.cmi`.

Merlin's optional external PPX result cache is unsupported. Its key does not
include the dependency interfaces that influenced the proof, so it could reuse
an expansion after an imported row changed. Keep it disabled as described in
the [public guide](./automatic-propagation.md#why-staged_pps-is-required).

OCaml-LSP delegates OCaml typing and hovers to Merlin. It therefore needs no
separate Hamlet extension. The acceptance harness tests both a saved document
and an unsaved `textDocument/didChange` update.

## Other PPXs

`hamlet-subtractor.ppx` owns the ordering between ordinary Hamlet expansion and
automatic elaboration. Another whole-file PPX that changes the input
computation, handler, service declarations, or catalogue must run before the
subtractor's evidence phase. Rewriting an already generated handler afterward
is unsupported unless the transformation is known to preserve its meaning.

The final AST contains no attributes used by the probe protocol, preventing a
later PPX from depending on Hamlet's internal links.

## Packaging and compatibility

The package installs:

- `hamlet-subtractor.ppx`;
- the compiler-independent proof and generation libraries;
- the private compiler compatibility and evidence code;
- the matching resolver executable.

The evidence layer uses internal compiler APIs, so a release targets one exact
OCaml patch and matching Hamlet/`ppx_hamlet` packages. The current target is
OCaml 5.5.0. Independently mixing versions is unsupported because their AST,
Typedtree, UIDs, or generated metadata may differ.

## Tests and debugging

The main feature gate is:

```sh
dune runtest test/automatic_propagation
```

It covers final types, runtime behavior, raw Merlin output, saved and unsaved
LSP hovers, dependency-interface invalidation, diagnostics, and cross-module
catalogues. `make installed-consumer` additionally proves the installed path in
a separate project. See the [test README](../test/automatic_propagation/README.md)
for focused commands.

When investigating a failure:

1. A configuration error usually means the target used `pps` instead of
   `staged_pps`.
2. An evidence refusal means the input row, source origin, handler arm, or
   catalogue could not be proved exact. First confirm the explicit fallback.
3. A marker-dependency refusal means an earlier marker produced opaque evidence
   or the value flow is outside the supported model.
4. A transport failure concerns resolver discovery, process execution, framing,
   or version correlation. It must never be hidden by a cached response.
5. A final compiler error after successful resolution indicates a mismatch
   between the proof and generated OCaml. Treat it as a subtractor bug.

When extending the accepted language, add the proof rule and a refusing
counterexample before adding the successful final-AST and editor tests.
