# Architecture and Data Flow

Automatic propagation is a staged subtraction performed by
`hamlet-subtractor.ppx`. Its job is to turn an automatic marker into ordinary
OCaml cases before the authoritative compiler or Merlin type check.

The implementation is built around one strict result:

> The PPX either proves an exact finite input row and returns a precise final
> AST, or it rejects the marker and asks for an explicit `%hamlet.te` or
> `%hamlet.ts` boundary.

It never returns a widened automatic fallback and never guesses runtime tags.

## End-to-end flow

```text
saved file or live editor buffer
              |
              v
Dune configuration
(staged_pps hamlet-subtractor.ppx)
              |
              v
combined Hamlet PPX driver
  ppx_hamlet declarations and explicit syntax
  automatic marker instrumentation
              |
              ├─ ocamldep
              │     |
              │     v
              │  dependency-safe bottom lowering
              │
              └─ compiler or Merlin
                    |
                    v
                 canonical base AST
                 plus temporary probe AST
                    |
                    v
                 bounded binary request
                 current AST, context, markers
                    |
                    v
                 lockstep resolver process
                 installed Dune site or
                 same-context source build
                 isolated compiler-libs typing
                 Typedtree evidence resolver
                    |
                    v
                 correlated binary response
                 exact rows and catalogues
                    |
                    v
                 dependency engine
                 one outcome per marker
                    |
                    v
                 final case generation
                 and marker replacement
                    |
                    v
                 ordinary final OCaml AST
                    |
                    v
                 final compiler or Merlin typing
                    |
                    v
                 exact build type and exact hover
```

The temporary compiler-libs check runs in Hamlet's lockstep resolver process
and is evidence collection. An installed PPX finds that process through the
package Dune site. An uninstalled PPX can derive the resolver in the same Dune
build context from its own `.ppx` executable path. It is not the final type
check. The final check sees the generated `fail`, `need`, direct variant, or
`Errors.Cases` code and remains authoritative.

## The two ASTs

`Hamlet_subtractor_probe.prepare` produces two related structures.

### Base structure

The base structure is the fully transformed user module with canonical marker
identities, but without probe-only upstream isolation lets. Final replacement
always starts from this structure. This prevents probe scaffolding from
appearing in generated code or Merlin output.

The base also marks the original upstream occurrence and owner for each
accepted marker. Those marks are not evidence by themselves. They tell final
replacement exactly where to install the ghost input and output certificate
constraints after the resolver has proved the source and residual. The marks
are removed with every other internal attribute before the AST leaves the PPX.

### Probe structure

The probe structure is temporary and type-safe. Each unresolved marker becomes
an ordinary bottom branch:

```ocaml
| _ -> (assert false [@hamlet.subtractor.marker.v1 "marker-id"])
```

Both the original handler and the owning upstream expression are typed in
independent bindings. The probe owner receives a separate bottom handler:

```ocaml
let _hamlet_subtractor_handler_marker_id =
  ((fun error ->
     match error with
     | handled -> recovery
     | _ -> (assert false [@hamlet.subtractor.marker.v1 "marker-id"]))
   [@hamlet.subtractor.handler.v1 "marker-id"])
in
let _hamlet_subtractor_upstream_marker_id =
  (source [@hamlet.subtractor.upstream.v1 "marker-id"])
in
Hamlet.Combinators.catch
  _hamlet_subtractor_upstream_marker_id
  ~handler:(fun _ -> assert false)
```

The handler binding preserves its Typedtree for arm and recovery analysis, but
it cannot widen the producer or owner result. The upstream binding prevents
patterns and recovery branches from forcing impossible tags into the producer
occurrence. Neither probe-created value scheme is accepted as proof. Evidence
must come from a marked original expression, an existing independently
generalized user value, a validated constructor trace, or a resolved marker
certificate.

Additional internal attributes connect the Typedtree nodes for the callee,
handler, owning result, upstream expression, and marker. All internal
attributes are removed before any final AST leaves the rewriter.

## Marker discovery

`ppx_hamlet` recognizes the surface extensions while the bundle is in probe
mode:

```ocaml
[%hamlet.propagate_e.auto]
[%hamlet.propagate_s.auto]
```

The Parsetree pass performs inexpensive structural checks first:

- the marker is the final arm;
- its body is the refutation expression `.`;
- its kind agrees with `catch` or `provide`;
- the handler is inline;
- the owner has a supported direct or pipeline call shape.

Each marker then receives a deterministic identity derived from the transformed
source digest, filename, kind, source span, and same-span ordinal. Identity is
needed only within the current invocation. No persistent marker cache is part
of correctness.

Parsetree owner discovery is only a candidate. Typedtree resolution later
checks the actual callee value UID against Hamlet's real `Combinators.catch` or
`Combinators.provide`. A local function with the same printed name is refused.

## Invocation modes

The same PPX executable behaves differently according to its caller.

- `ocamldep`: keep dependency-bearing syntax, lower markers to bottom, strip
  internal attributes, and never invoke the typer.
- `ocamlc` or `ocamlopt`: resolve the probe, replace every marker, and return
  the final AST.
- Merlin: resolve the live buffer through the same path and return the same
  final AST shape.
- Dune fast preprocessing: reject auto markers and require
  `staged_pps hamlet-subtractor.ppx`.
- Unknown context: reject auto markers because the required compilation
  context cannot be proved.

Dependency discovery cannot type the module because sibling CMIs may not exist
on a clean build. The later compiler invocation sees Dune's scheduled
dependencies and can perform exact resolution.

## Compiler evidence stage

The PPX serializes the already transformed probe with OCaml's binary AST
format. It does not reread, print, or reparse the source, so live editor text
and exact source locations survive the process boundary. The request is sent
to the resolver selected from the installed Dune package site or the
same-context uninstalled build fallback. Neither path searches `PATH`. The
response must match the request identity, semantic context digest, binary AST
digest, and complete marker set before the PPX accepts it.

Inside that process, `Hamlet_subtractor_compiler_compat` restores the portion of the
active compiler context transported by the standard PPX protocol, initializes
the visible and hidden load paths, creates the initial environment, and types
the probe in an isolated compiler store. Warnings and delayed checks are
suppressed for this temporary pass so users see them only once from the final
compiler. Nondefault compiler modes omitted by the standard protocol are
outside the supported configuration and require an explicit propagation
boundary.

`Hamlet_subtractor_compiler_evidence` consumes the Typedtree while compiler values
are alive. It performs six jobs:

1. verify the real Hamlet owner UID and linked marker nodes;
2. locate the actual upstream producer rather than the widened handler input;
3. trace a supported concrete source or local builder before applying the
   principal-row closing check;
4. normalize exact error and requirement rows into compiler-independent
   proofs;
5. validate generated declaration metadata and cross-unit catalogues;
6. classify preceding arms and recovery computations.

No `Types.type_expr`, `Typedtree.expression`, `Env.t`, or compiler UID crosses
the compatibility boundary. The result consists only of values owned by
`Hamlet_subtractor_core` and `Hamlet_subtractor_catalogue`.

## Dependency engine

Markers may depend on earlier marker results. A common example is a second
`catch` over the output of a first `catch`, or a `provide` after a direct
generated `Tag.summon` recovery introduced an exactly certified requirement.

`Hamlet_subtractor_engine` receives:

- every marker;
- its exact or refused evidence;
- typed value-binding dependency edges;
- verified catalogues;
- full two-channel certificates from resolved dependencies.

It resolves ready markers in deterministic marker-ID order. A resolved marker
contributes both its target residual and its error and requirement certificate
to one directly proven successor. Refused or opaque dependencies make the
consumer opaque. Cycles and multi-input marker compositions receive a
deterministic dependency diagnostic instead of an arbitrary iteration limit.

The resolved set grows monotonically. No resolved marker is reconsidered with
weaker evidence.

## Final generation

`Hamlet_subtractor_generator` uses only the certified residual and catalogue data.
It has four output forms.

### Direct named leaf

```ocaml
| #Storage.Errors.write_error as error ->
    Hamlet.Combinators.fail error
```

This is used for a materializable local leaf or a certified proper external
subset.

### Structural variant

```ocaml
| `Retry_later as error -> Hamlet.Combinators.fail error
| `Unavailable _ as error -> Hamlet.Combinators.fail error
```

This is allowed only for a closed, unambiguous singleton structural leaf with
known payload arity.

### Full external catalogue

For a verified complete external service universe, generation reuses
`Service.Errors.Cases.propagate` and `Cases.dispatch`. Fields handled by prior
unguarded arms become unreachable callbacks. The producer interface and the
consumer expansion remain linear in the declared number of leaves.

### Exhausted universe

When no residual leaf remains, generation keeps an unreachable final case.
This preserves OCaml warning 11 for a redundant marker. The PPX does not hide
that useful warning.

Every generated nonempty fallback ends with a ghost wildcard refutation. The
final compiler accepts that case only when the forwarding patterns cover the
actual handler input. An exhausted fallback keeps the refutation and then the
redundant unreachable case responsible for warning 11.

Replacement also constrains each resolved owner to its complete output
certificate:

```ocaml
(elaborated_owner : (_, exact_errors, exact_requirements) Hamlet.t)
```

An exact empty channel becomes `Hamlet.never`; an intentionally opaque channel
becomes `_`. Exact leaves must be materializable as ordinary source types or
replacement refuses. This constraint prevents recovery branches or later
dependent handlers from contextually widening an already proven result.

Before that owner constraint, replacement constrains the original marked
upstream occurrence to the input certificate for the marker's target channel.
The opposite channel is exact when independently proven and `_` otherwise.
The final compiler therefore checks both sides of the calculation: the source
that supplied the residual and the handled effect that consumed it.

`Hamlet_subtractor_replace` substitutes generated cases into the base structure,
checks that every marker and canonical owner appears exactly once, and removes
every internal marker, upstream, callee, handler, and owner attribute. User
attributes remain on the original owner expression, not on the generated
constraint wrapper.

## Error example

Assume the certified source error universe is:

```text
{ read_error, write_error, network_error }
```

The user handles `read_error` with an unguarded complete arm. Recovery may add
`recovery_error`.

```text
input                { read_error, write_error, network_error }
handled              { read_error }
generated residual   { write_error, network_error }
recovery contribution{ recovery_error }
final error proof    { write_error, network_error, recovery_error }
```

Only the generated residual becomes fallback cases. Recovery code remains
unchanged and contributes its own row through ordinary OCaml typing. A direct
canonical recovery retains a full certificate for a dependent marker. An
indirect recovery remains valid for this marker but makes both downstream
certificate channels opaque.

## Requirement example

Assume the source requires:

```text
{ Logger, Clock, Database }
```

An unguarded direct `Logger.Tag.give` arm discharges `Logger`. An explicit
`Clock` arm calling `Dispatch.need` forwards `Clock`. The generated fallback
needs `Database`.

```text
input                { Logger, Clock, Database }
discharged           { Logger }
explicitly forwarded { Clock }
generated residual   { Database }
final requirements   { Clock, Database }
```

The requirement calculation does not remove or rewrite the program's error
channel.

## Why the final type is precise

The final compiler never types an unresolved auto marker and never sees a
full-universe fallback chosen for convenience. It sees only cases generated
from the demonstrated residual. Recovery branches are unchanged, so OCaml
unifies their normal error and requirement contributions with those exact
generated cases.

Merlin runs the same configured PPX against the current buffer before its own
typing query. Hover therefore describes the final expansion rather than a
later linter suggestion or a manually edited annotation.

The acceptance harness checks that claim at three separate boundaries. It
inspects raw Merlin `ppxed-source`, inspects the Typedtree Merlin actually
types, and requests exact hover types from saved and unsaved buffers. An
embedded `ocaml.error`, probe assertion, or retained internal attribute fails
the harness even if a later query could still print a plausible type.
