# Proof and Soundness Model

The resolver does not ask whether forwarding would probably work. It builds a
finite proof that every generated case corresponds to a value already present
in the statically known input row.

This distinction matters because OCaml polymorphic variant rows can be open,
abstract, contextually widened, or rooted in a caller-controlled type
parameter. A normal PPX cannot treat the visible lower bound of such a row as
its complete runtime universe.

## Core vocabulary

The compiler-independent model lives in `Hamlet_subtractor_core`.

- `Identity.t`: a nominal declaration path plus an interface or source
  fingerprint.
- `Type_identity.t`: a normalized payload type used to distinguish equal
  labels with different payloads.
- `Atom.t`: one polymorphic variant label, channel, payload shape, and declaring
  identity.
- `Leaf.t`: one complete unit of subtraction, possibly containing several
  atoms.
- `Proof.t`: a finite non-overlapping set of leaves for one Hamlet channel and
  its evidence origin.
- `Effect_certificate.t`: independent evidence for both the error and
  requirement channels.
- `Residual.t`: the input proof, classified arms, handled leaves, forwarded
  leaves, recovery leaves, generated residual, and output proof.
- `Diagnostic.t`: a marker-local refusal code and explicit fallback
  information.

Compiler-libs nodes are converted into these values before the temporary
typing session is reset.

## Nominal identity and structural shape

Hamlet needs both nominal and structural information.

Nominal identity answers:

```text
Is this Storage.Errors.read_error from this compiled interface?
```

Structural shape answers:

```text
Is this `Read_error of string at runtime?
```

`Identity.t` contains:

- a source-reachable module path;
- a declaration name;
- a stable fingerprint of the defining interface, or the current source when
  the declaration belongs to the module being compiled.

The semantic fingerprint must not depend on whether the caller is `ocamlc`,
`ocamlopt`, or Merlin. Paths are normalized through the typing environment so
module aliases do not create different identities for the same declaration.

`Atom.equal` includes nominal identity. `Atom.equal_structural` compares the
channel, label, and normalized payload while ignoring where the atom was
declared. Structural comparison is used only during validated catalogue
partitioning and ambiguity checks.

## Payload normalization

Variant payloads are normalized without printing compiler types. Supported
forms include primitives, tuples, and nominal constructors whose arguments are
also normalizable.

Normalization records whether a variant has zero or one payload argument. The
generator uses that arity to choose between:

```ocaml
`Label
`Label _
```

Unresolved variables, functions, objects, packages, open variants inside a
payload, and unsupported structural types cause a refusal. Two requirement
tags with the same label but different `Tag.t Hamlet.P.t` payload identities
therefore remain distinct.

## Leaves and materialization

A leaf is the smallest unit that may be subtracted by one complete arm.

Generated Hamlet errors normally use one declared leaf alias:

```ocaml
type read_error = [ `Read_error of string ]
```

A leaf can contain more than one atom if the declaration groups tags. Such a
leaf must remain whole. The resolver refuses a row or arm that contains only a
proper subset of its atoms.

Every leaf records how final source can materialize it:

- `Direct`: `#Module.Errors.leaf`.
- `Structural_variant`: a raw polymorphic variant pattern with certified arity.
- `Error_cases`: a direct proper-subset arm or full `Errors.Cases` dispatch.
- `Requirement_tag`: `#Service.Tag.r`.
- `Unavailable`: never generated and causes an explicit fallback refusal.

Materialization is part of the proof obligation. Knowing that an atom exists
is not enough if no ordinary type-safe OCaml pattern can represent it.

## Accepted row evidence

There are three useful evidence sources.

### Finite closed row

After transparent alias expansion, a direct row is exact only when all of the
following hold:

- it is `Hamlet.never` or a polymorphic variant row;
- the row is closed;
- the flattened tail is `Tnil`;
- the row is not fixed or private;
- every relevant field is present;
- no `Reither` or absent field is used as positive evidence;
- every payload normalizes.

Abstract aliases and hidden manifests are not opened by guesswork. A visible
transparent alias may be expanded, while a private or unresolved boundary is
refused.

### Independently generalized principal value

Typical Hamlet programs infer open lower bounds:

```ocaml
val program : ('a, [> `Missing | `Timeout ], [> Logger.Tag.r ]) Hamlet.t
```

The visible tags are not automatically a finite universe. They become exact
only under a narrower principal-scheme proof:

1. the origin is an external value description or a binding reached by the
   supported immutable effect-value provenance tracer;
2. evidence comes from that value's original scheme, never the
   context-instantiated occurrence or the probe-created isolation binding;
3. all visible fields are present and the only tail is one unconstrained
   generic variable;
4. a fresh instance can be closed to the visible fields without constraining
   anything in the surrounding lexical environment;
5. typed UID provenance does not lead to a parameter, mutable cell, object
   field, unverified first-class module escape, or opaque higher-order input.

The fresh closing check is performed on a copy. The user's scheme is never
mutated.

This proof is available only inside the supported compiler configuration. The
standard PPX context carries principal mode and the other modes listed in the
integration guide, but it omits several OCaml command-line options. A target
using a nondefault omitted mode must place an explicit propagation boundary at
the handler. The elaborator cannot prove parity for context it never receives.

### Traced concrete source and local builder

The principal-scheme rule also applies to an unannotated local source when the
resolver can prove that the source was built independently of the handler's
context. This does not treat a visible lower bound as a universe. The trace
only authorizes the existing fresh-instance closing check on the source's
principal scheme.

The traced domain is intentionally small:

- direct canonical `success`, `return`, `fail`, and `summon` calls;
- generated `Tag.summon` calls whose declaration has the service-tag metadata;
- Hamlet-effect applications through a local module identifier only when that
  identifier was package-typed by the PPX and unpacked from a verified generated
  summon; the lowered `Combinators.summon` key/tag pair must identify the same
  generated service;
- direct canonical `Combinators.chain`, `both`, `map`, `catch`,
  `catch_defect`, `map_fail`, `or_die`, `thaw`, `tap`, `tap_fail`,
  `tap_defect`, and `tap_cause` calls when every contributing source and
  callback result traces independently;
- `let*` and `let+` expressions whose operators resolve to Hamlet's real
  binding operators, with independently traced inputs, `and*` operands, and
  result body where applicable;
- ordinary `let` and structure-item wrappers, a sequence's final expression,
  and `match` or total `if` branches only when every possible result traces;
- a direct application of a locally bound builder whose function body traces
  independently.

Names are not evidence. Every listed call and binding operator is validated by
its resolved Hamlet UID. A local builder must have an independently generalized
function scheme, be called directly with positional arguments, and have a
result whose target channel shares no free type variable with any applied
argument parameter. The selected target channel can then use the builder
result scheme for the usual fresh closing check. This admits a concrete
`unit -> Hamlet.t` builder while refusing a helper such as
`fun error -> Hamlet.Combinators.fail error`, whose result error channel depends
on its argument.

The opposite channel is still independently exact or opaque. Exactness for one
channel never fabricates an exact proof for the other. Higher-order callbacks,
mutable or object sources, unverified first-class module escapes, indirect
combinator aliases, unsupported branches, recursive builders, labelled or
optional local builder applications, and any unrecognized composition refuse.

### Certified computation

Some expressions are proven compositionally rather than from an occurrence
row. The proof tracer recognizes real Hamlet value UIDs and combines only
certified operands.

Important constructors include:

- `success` and `return`: empty error and requirement proofs;
- direct `fail`: one exact error leaf;
- generated `Tag.summon`: one exact requirement leaf;
- a resolved auto `catch`: its output certificate;
- a resolved auto `provide`: its output certificate.

A printed name is never sufficient. A local `fail`, `catch`, or `give`
lookalike is refused. Immutable aliases of already proven effect values may be
followed, but aliases of the combinator functions are not canonical calls. The
traced concrete-source rule above admits only its audited direct composition
forms. Arbitrary or higher-order producer flows are refused.

## Catalogue evidence

`ppx_hamlet` places compiler-visible attributes on generated declarations:

```text
hamlet.subtractor.error_leaf.v1
hamlet.subtractor.error_union.v1
hamlet.subtractor.error_cases.v1
hamlet.subtractor.service_tag.v1
```

The attributes identify candidates. The resolver still validates the actual
typed declarations.

For an error service it checks:

1. `Errors.error` is a transparent finite union;
2. every `Errors.Cases.t` field is a callback whose domain is one declared
   error leaf;
3. field names and leaf paths are unique;
4. leaf manifests normalize to disjoint atom sets;
5. the fields form a complete partition of `Errors.error`;
6. the catalogue identity and dependency interface fingerprint agree.

An inferred structural row is matched against complete validated partitions,
not merely against leaves mentioned by user arms. The mapping must be unique.
Unknown atoms, overlapping candidate partitions, a partly present grouped
leaf, or a full external universe without `Errors.Cases` is refused.

For a proper certified external subset, each remaining whole leaf can be
generated directly. For the complete external universe, the full catalogue is
retained so generation uses the linear `Cases` protocol.

For requirements, a generated `Tag.r` must contain exactly one tag carrying
the expected `Tag.t Hamlet.P.t` payload. A custom alias grouping several
services is not treated as one dischargeable leaf.

## Arm classification

The resolver uses both source shape and Typedtree identity.

An error arm is complete when it is exactly:

```ocaml
#Path
#Path as name
```

Harmless constraint or alias wrappers may surround the pattern. The Typedtree
must contain the expected `Tpat_type` expansion and the resolved declaration
must match one certified leaf.

A user-authored or-pattern, wildcard, variable, raw partial payload pattern, or
mixed structural pattern is refused. The classifier must distinguish an
internal or-pattern created by OCaml's `#Path` expansion from an or-pattern
written by the user.

Requirement subtraction additionally verifies the RHS:

- direct `Tag.give witness implementation` marks the service handled;
- direct `Hamlet.Dispatch.need witness` marks it explicitly forwarded;
- the witness must be the variable bound by that exact arm;
- helpers or unrelated witnesses are refused.

For error arms, direct `fail error` using the bound alias is explicit
forwarding. Other RHS computations are recovery branches and receive their own
certificate.

## Guards

Every preceding leaf pattern is validated against the input universe, even
when guarded. A guard changes subtraction only:

```text
unguarded complete Handle  subtract leaf
unguarded complete Forward keep output through explicit branch
guarded Handle             subtract nothing
guarded Forward            subtract nothing
```

When a guard is false, evaluation continues to the generated marker branch.
Keeping the leaf in the residual is therefore required for runtime soundness.

## Residual calculation

For one channel, define:

```text
U = certified input leaves
H = unguarded complete handled leaves
F = unguarded complete explicitly forwarded leaves
C = exact recovery contributions for this channel
```

The generated fallback is:

```text
R = U minus H minus F
```

The final output proof is:

```text
O = R union F union C
```

`Residual.residual` is used for generated cases. `Residual.output` is used for
the certificate passed to dependent markers. Keeping these projections
separate prevents recovery errors from becoming fabricated fallback patterns.

Duplicate unguarded arms, arms outside `U`, conflicting recovery leaves, and
unmaterializable members are refusals.

## Two-channel certificates

Each marker resolves one target channel but must preserve both.

For `catch`:

```text
errors       = propagated residual errors union recovery errors
requirements = source requirements union recovery requirements
```

For `provide`:

```text
errors       = source errors
requirements = forwarded and residual requirements
```

The certificate carries exact or opaque evidence independently for each
channel. This matters when a recovery function is legal OCaml but cannot be
traced exactly.

An opaque recovery does not invalidate generation for the current marker. Its
user branch remains unchanged and the final compiler types it normally. Both
certificate channels become opaque, so a later automatic marker that needs an
exact result refuses and asks for an explicit boundary.

## Final AST proof obligations

The temporary Typedtree is evidence, not authority. Final generated source
contains two independent checks that the ordinary compiler types again.

First, generated forwarding cases end with a ghost wildcard refutation. This
detects an underapproximated residual because the wildcard can be refuted only
when the preceding generated patterns cover the handler input. The exhausted
case retains an additional unreachable wildcard so warning 11 remains visible.

Second, the original upstream occurrence is constrained to the certified input
row for the marker's target channel. Its opposite channel uses an exact proof
only when one is available, otherwise `_`. This stops the final handler from
contextually widening the very source from which the residual was derived.

Third, each resolved `catch` or `provide` owner is constrained to the full
two-channel output certificate:

```ocaml
(_, exact_errors, exact_requirements) Hamlet.t
```

An exact empty proof materializes as `Hamlet.never`. Opaque evidence
materializes as `_`. Every exact nonempty proof must materialize as a closed
ordinary polymorphic-variant row, otherwise elaboration refuses. This
constraint prevents recovery polymorphism or a dependent marker from widening
the proven owner result after replacement.

The refutation prevents missing runtime cases. The input and output constraints
prevent contextual widening. None permits the resolver to accept a row that it
could not prove from the transported compiler context.

## Dependent markers

Dependencies are derived from typed value UIDs and certified composition, not
only from physical AST nesting.

This must work:

```ocaml
let first =
  Hamlet.Combinators.catch source
    ~handler:(fun error ->
      match error with
      | #Errors.a -> recover_a
      | [%hamlet.propagate_e.auto] -> .)

let second =
  Hamlet.Combinators.catch first
    ~handler:(fun error ->
      match error with
      | #Errors.b -> recover_b
      | [%hamlet.propagate_e.auto] -> .)
```

The bottom-lowered probe result for `first` is never accepted as the universe
of `second`. The UID edge causes the engine to resolve `first`, then supply its
full certificate to `second`.

The engine orders ready markers deterministically. It supports a direct chain
with zero or one proven marker predecessor at each step. Multi-source marker
composition, opaque edges, and unsupported higher-order combinations refuse.
Strongly connected marker components receive a recursive-dependency
diagnostic.

## Permanent refusal boundary

Automatic elaboration refuses when exact evidence is unavailable, including:

- abstract, hidden, private, fixed, or genuinely open rows;
- parameter-rooted or unresolved row variables;
- unsupported higher-order, mutable, object, or unverified first-class module
  flows;
- ambiguous structural-to-nominal catalogue mapping;
- partial grouped leaves;
- unsupported patterns or requirement helper calls;
- unmaterializable payloads;
- missing cross-unit catalogue support;
- recursive marker dependencies.

The fallback is ordinary typed Hamlet code with an explicit `%hamlet.te` or
`%hamlet.ts` universe. Refusal is part of the soundness model, not a degraded
automatic mode.

## Soundness checklist

Before a new evidence path is accepted, its tests must establish all of these:

1. The source of the row cannot have hidden additional leaves.
2. Nominal identities are stable across compiler, native compiler, and Merlin.
3. Module aliases normalize to the same declarations and payload identities.
4. Every input atom maps to exactly one complete materializable leaf.
5. Guarded and partial control flow cannot reach an unreachable generated
   callback.
6. Recovery evidence is traced before handler contextual widening.
7. Let-bound direct marker chains carry dependency certificates.
8. The final wildcard refutation validates complete forwarding coverage.
9. The owner-result constraint materializes the complete output certificate.
10. The final compiler sees no probe scaffolding or internal attributes.
11. Failure points to the responsible marker and names the explicit fallback.
