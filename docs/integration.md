# Compiler and editor integration

Applications configure one PPX. The resolver is an implementation detail: the
PPX starts it when typed evidence is needed, and consumers never invoke it from
Dune or the shell.

## Why `staged_pps` is required

Dune processes an OCaml module twice for two different purposes.

1. It first asks `ocamldep` which other modules the source imports. Some of
   those modules may not have been compiled yet.
2. After building the imported modules, it runs the PPX for `ocamlc`,
   `ocamlopt`, or Merlin and then type-checks the result.

A compiled public interface is a `.cmi` file. It contains the types and
declaration identities exported by a module. Hamlet Subtractor needs those
facts to distinguish, for example, a real `Storage.Errors.read_error` from an
unrelated type with the same printed name.

With ordinary `pps`, Dune expects the early dependency pass to produce the
final expansion. That is too soon for cross-module proofs because an imported
`.cmi` may not exist. With `staged_pps`, the dependency pass receives a safe
syntax-only result and the later compiler pass performs automatic
elaboration, after dependency interfaces are available.

```lisp
(preprocess
 (staged_pps hamlet-subtractor.ppx))
```

Targets that use no subtractor marker or generic helper may use
`(pps ppx_hamlet)` instead.

## What happens in the later pass

The PPX:

1. runs ordinary `ppx_hamlet` rewriting;
2. keeps the program it will eventually return as the base AST;
3. creates a temporary probe AST with links between each marker, owner,
   handler, and input;
4. sends the probe and compiler context to the resolver;
5. receives immutable evidence, computes the residual rows, and generates
   forwarding code;
6. inserts that code into the base AST and removes all internal links.

The probe is typed only to obtain evidence. It is discarded. The compiler or
Merlin then types the final generated program normally, so the proof cannot
replace the ordinary OCaml type check.

Generic helpers use the same round trip. A definition exports a small symbolic
contract in a hidden generated module declaration that survives in its `.cmi`.
A call containing
`[%hamlet.forward.auto]` loads that contract from the callee's `.cmi`, applies
it to the caller's concrete rows, and generates exhaustive evidence records.

## Resolver process

OCaml compiler libraries contain mutable global state. Running an extra type
check inside the PPX process could contaminate the compiler or Merlin session.
The resolver therefore types the probe in a fresh process and exits after one
request. Compiler environments, mutable type variables, and Typedtree nodes
never return to the PPX.

The request carries the probe AST, source locations, supported compiler flags,
include paths, marker and contract expectations, and version fingerprints. The
response carries exact proof values or a structured refusal. Each response
must match the request ID and expected markers. Missing results, duplicates,
timeouts, crashes, oversized payloads, and version mismatches are errors.

### How the PPX finds it

An installed package records where its own resolver executable was installed.
The PPX reads that package location and starts the resolver shipped with the
same installation.

This repository is different only because its test package is not installed.
The test fixture declares the resolver as a build dependency, and the PPX finds
it inside the same Dune build context as the running `.ppx` executable.

Neither path searches `PATH`. Searching `PATH` could select a resolver from a
different checkout, opam switch, compiler version, or package release.
Consumers need no `preprocessor_deps`; the source-tree fixture needs one only
to make its uninstalled resolver exist before Merlin starts.

## Dependency interfaces and editor freshness

Suppose the active file is `A.ml` and it imports `B`.

- Merlin sends the current unsaved contents of `A.ml` through the PPX.
- Information about `B` comes from the last built `B.cmi`.

Editing or saving `B.ml` does not itself change `B.cmi`. Rebuild `B` before
expecting its new exported API to affect automatic propagation in `A.ml`.
Once Dune writes the new interface, the next analysis of `A.ml` sees it.

Do not enable Merlin's optional external PPX result cache. The source text of
`A.ml` can remain unchanged while a rebuilt `B.cmi` adds an error or service.
That must change the generated forwarding cases. The optional cache does not
include dependency-interface contents in its key, so it may reuse an expansion
created for the old `B.cmi`. Dune's normal Merlin setup leaves this cache off.

OCaml-LSP obtains types and hovers from Merlin, so it needs no Hamlet-specific
extension. Saved builds, unsaved Merlin buffers, and LSP documents all receive
the same final expansion.

## Compiler context and limits

The resolver reconstructs the compiler settings exposed through the standard
PPX context: include paths, opened modules, package wrapping, and supported
typing flags. It also checks the exact OCaml, AST, protocol, PPX, and resolver
versions.

OCaml does not expose every command-line option to a PPX. If a target uses an
unreported nondefault typing mode, automatic proof is refused; use an explicit
`%hamlet.te` or `%hamlet.ts` boundary unless that mode is specifically tested.
The current implementation supports POSIX systems and targets OCaml 5.5.0.

## Diagnostics

Locations come from the live input AST. User-facing generated cases keep the
marker location; internal nodes use ghost locations. Resolver typing failures
are mapped back to the nearest source construct.

A refusal means one of three things:

- the Dune target used the wrong PPX phase;
- the effect row, handler, generic contract, or dependency flow was not exact;
- the resolver could not run or its response did not match the request.

The diagnostic names the failed condition and the available explicit boundary.
A final compiler error after successful generation is a subtractor bug, because
the final compiler remains authoritative.

## Other PPXs and packaging

`hamlet-subtractor.ppx` owns the ordering between `ppx_hamlet`, evidence
collection, and final replacement. A whole-file PPX that changes Hamlet
computations or handlers must run before this evidence phase. Internal probe
attributes are removed before later processing.

The package installs the public evidence type, PPX, proof and generation
libraries, compiler-specific private code, and the matching resolver. Mixing a
resolver, PPX, Hamlet package, or OCaml compiler from another supported pair is
not valid.

The full compiler/editor gate is documented in the
[acceptance-test README](../test/automatic_propagation/README.md).
