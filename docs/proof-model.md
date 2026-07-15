# Proof and soundness model

The subtractor generates a forwarding case only after proving that its pattern
belongs to the complete input row. It never treats the tags currently visible
in a type as the complete runtime universe.

This matters because an OCaml polymorphic-variant type can be open:

```ocaml
[> `Missing | `Timeout ]
```

That type says `Missing` and `Timeout` are possible; it does not say they are
the only possibilities. Forwarding only those two tags would be unsound unless
the PPX has separate evidence that the row can be closed exactly there.

## Core values

The compiler-independent model lives in `subtractor/core` and is exposed as
`Hamlet_subtractor_core`.

| Value | Meaning |
| --- | --- |
| `Identity.t` | The declaration that owns a leaf, plus a fingerprint of its source or compiled interface. |
| `Type_identity.t` | A normalized payload type used to distinguish otherwise similar tags. |
| `Atom.t` | One polymorphic-variant label with its channel, payload, and declaring identity. |
| `Leaf.t` | The smallest complete unit that one handler arm may subtract. A generated alias can contain several atoms. |
| `Proof.t` | A finite, non-overlapping set of leaves for one channel, together with the origin of that evidence. |
| `Effect_certificate.t` | Independent evidence for the error and requirement channels of one computation. |
| `Residual.t` | The input, classified arms, handled leaves, forwarded leaves, recovery contributions, generated residual, and final output. |
| `Diagnostic.t` | A stable refusal reason, source span, and explicit fallback. |

The Typedtree evidence layer converts compiler values into these immutable
values before the resolver destroys its temporary compiler session.

## Identity, shape, and payloads

The proof needs both nominal identity and runtime shape.

Nominal identity answers:

```text
Is this the read_error declared by this Storage interface?
```

Structural shape answers:

```text
Is its runtime pattern `Read_error of string?
```

`Identity.t` records a normalized module path, declaration name, and a
fingerprint of the defining source or `.cmi`. Module aliases normalize to the
same declaration. This prevents a declaration with the same printed name from
being mistaken for the original one.

Payload types are normalized without printing compiler types. Supported forms
include primitive types, tuples, and nominal type constructors whose arguments
can also be normalized. The proof records whether a variant has zero or one
payload argument so generation can choose:

```ocaml
`Label
`Label _
```

Functions, objects, packages, unresolved variables, nested open variants, and
other unsupported payloads are refused. Requirement tags with the same label
but different `Tag.t Hamlet.P.t` payload identities therefore remain distinct.

## Leaves and materialization

A leaf is the smallest unit a complete arm can handle. A normal generated error
leaf looks like:

```ocaml
type read_error = [ `Read_error of string ]
```

Some aliases group several atoms. Such a leaf remains indivisible: neither the
input proof nor a handler arm may claim only part of it.

Every proven leaf must also have a safe source-level representation. The
generator can use:

- a named error pattern such as `#Storage.Errors.read_error`;
- a structural variant whose label and payload arity are exact;
- a validated `Errors.Cases` catalogue for a generated external universe;
- a requirement pattern such as `#Logger.Tag.r`.

A row is refused if a leaf is known to exist but cannot be represented by
ordinary type-safe OCaml code.

## Accepted sources of exact rows

The resolver accepts four kinds of evidence.

### 1. Closed row

A direct row is exact after transparent alias expansion when:

- it is `Hamlet.never` or a closed polymorphic-variant row;
- its tail is empty;
- it is not private or fixed;
- every relevant field is present;
- every payload can be normalized.

Abstract, private, hidden, and unresolved aliases are not opened by guesswork.
A visible transparent alias may be expanded.

### 2. Independently generalized value

OCaml often prints a principal value with an open lower bound:

```ocaml
val program : ('a, [> `Missing | `Timeout ], [> Logger.Tag.r ]) Hamlet.t
```

The printed `[> ... ]` is only a lower bound. The extra fact comes from how an
exported value is typed: OCaml stores a reusable type scheme and creates fresh
type variables each time the value is used.

The resolver copies that scheme for the current use. On the copy, it tries to
replace the row's “possibly more tags” tail with an empty tail. The test is
accepted only when that change is local to the copy. It must not also restrict
an argument, callback, or other type variable owned by surrounding code.

Concretely, all of these conditions must hold:

1. the type comes from the value's independently generalized definition, not
   from a handler-widened occurrence;
2. the only row tail is one unconstrained generic variable;
3. closing a fresh copy does not constrain any surrounding type variable;
4. provenance does not lead to a function parameter, mutable cell, object
   field, unknown first-class module, or opaque higher-order input.

The check never mutates the exported declaration or the caller's types. A
simple value defined as `let program = fail `Missing` normally passes. A
function defined as `let build error = fail error` fails because closing its
result would also restrict the caller's `error` argument.

### 3. Traced concrete computation

The resolver can trace a deliberately small set of real Hamlet expressions:

- direct `success`, `return`, `fail`, and generated `Tag.summon` calls;
- row-preserving composition such as `chain`, `both`, `map`, `catch_defect`,
  `tap*`, `ensuring`, and `acquire_use_release`;
- error-replacing composition through `catch`, `catch_cause`, `catch_filter`,
  and `catch_cause_filter` when every recovery path is exact;
- row-clearing or row-transforming wrappers such as `or_die`, `sandbox`,
  `scoped`, and explicitly closed `map_fail` or `provide` calls;
- Hamlet `let*`, `and*`, and `let+` composition;
- ordinary immutable `let` wrappers, the final expression of a sequence, and
  control-flow branches when every possible result is proven;
- a directly applied local builder whose body and result are independent of
  its arguments.

Each call is checked by its resolved Hamlet UID. Printed names are not
evidence, and an alias of a combinator function is not treated as a direct
canonical call.

For a first-class service module, all of these conditions are required:

1. the local module was unpacked from a generated `Tag.summon`;
2. `ppx_hamlet` attached the expected package type to the unpack pattern;
3. the lowered primitive summon key and tag identify the same generated
   service;
4. the method application through that local module has Hamlet's effect shape.

This proves calls such as `Logger.log` and `Clock.now` after verified summons.
It does not authorize arbitrary first-class module values.

A local builder must be independently generalized, called directly with
positional arguments, and return a target row that shares no free type variable
with its applied arguments. This admits the common `unit -> Hamlet.t` builder
and refuses a function such as `fun error -> fail error`, whose output row
depends on its input.

The error and requirement channels are proven independently. Exact evidence
for one never fabricates evidence for the other.

### 4. Certified earlier marker

A resolved automatic `catch` or `provide` produces a complete two-channel
certificate. A later marker may use that certificate when Typedtree value
identity proves that it consumes the earlier result.

If supported composition surrounds that result, the resolver builds a source
plan. Each node records the primitive's real row equation:

- preserve and union exact contributors for `chain`-like composition;
- replace source errors with exact recovery errors for `catch`-like
  composition;
- clear a channel for `or_die`, `sandbox`, or `scoped`;
- use an explicitly proven output channel for `map_fail`, `provide`, or
  `scoped_with`.

The engine substitutes the earlier marker certificate into that plan before
resolving the later marker. This keeps effects introduced between markers and
also prevents handled errors from incorrectly surviving an ordinary `catch`.

## Generated catalogues

`ppx_hamlet` marks generated declarations as error leaves, error unions,
`Errors.Cases` catalogues, or service tags. Attributes identify candidates;
the resolver still validates the typed declarations.

For an error catalogue it checks that:

1. the exported error type is a transparent finite union;
2. every catalogue field accepts one declared leaf;
3. field names and leaf paths are unique;
4. leaf atom sets do not overlap;
5. the fields form a complete partition of the error union;
6. declaration identities and dependency-interface fingerprints agree.

An inferred structural row must map uniquely to complete validated leaves.
Unknown atoms, ambiguous partitions, partial grouped leaves, and a complete
external universe without a catalogue are refused.

For requirements, a generated `Tag.r` must contain exactly one tag with the
expected service payload identity. An alias grouping several service tags is
not one dischargeable leaf.

## Handler arm classification

An error arm is complete only in one of these forms:

```ocaml
#Path
#Path as name
```

The Typedtree expansion of `#Path` must resolve to one certified leaf. A
wildcard, variable, partial payload pattern, or user-written or-pattern is not
complete evidence.

For a requirement arm, the right-hand side is also checked:

- `Tag.give witness implementation` marks the service as handled;
- `Hamlet.Dispatch.need witness` marks it as explicitly forwarded;
- `witness` must be the variable bound by that same arm.

For an error arm, direct `fail error` using the bound alias is explicit
forwarding. Other right-hand sides are recovery computations.

A guard always prevents subtraction. If the guard is false, control reaches
the generated final arm, so that leaf must remain in the residual.

## Residual equations

For one channel:

```text
U = certified input leaves
H = unguarded leaves handled by user code
F = unguarded leaves explicitly forwarded by user code
C = exact effects introduced by recovery code

R = U - H - F
O = R union F union C
```

`R` is the set for which the PPX generates fallback cases. `O` is the output
proof passed to a later dependent marker.

Keeping them separate is essential: a recovery error belongs in the output
type, but it was not present in the original input and must not become a
generated input pattern.

Duplicate complete arms, arms outside `U`, conflicting recovery leaves, and
unmaterializable residuals are refused.

## Two-channel certificates

Every marker preserves both Hamlet effect channels.

For `catch`:

```text
errors       = residual input errors union recovery errors
requirements = source requirements union recovery requirements
```

For `provide`:

```text
errors       = source errors
requirements = explicitly forwarded and residual requirements
```

Evidence for either channel is `exact` or `opaque`. Opaque recovery code does
not invalidate the current marker: the branch remains unchanged and the final
compiler types it. It does prevent a later marker from relying on an exact
certificate for that result.

## Checks in the final AST

The probe Typedtree supplies evidence, but the final compiler remains the
authority. Generated source contains three normal OCaml checks:

1. A ghost wildcard refutation follows generated forwarding patterns. It
   type-checks only if those patterns cover the handler input.
2. The original input expression is constrained to the row from which the
   residual was computed. This prevents handler context from widening the
   source afterward.
3. The final `catch` or `provide` expression is constrained to the complete
   error-and-requirement certificate. This prevents recovery code or a later
   marker from widening the proven output.

An exact empty channel becomes `Hamlet.never`; opaque evidence becomes `_`.
Every exact nonempty row must be expressible as a closed OCaml type or
replacement refuses.

## Dependent markers

Consider:

```ocaml
let first =
  Hamlet.Combinators.catch source ~handler:(fun error ->
    match error with
    | #Errors.a -> recover_a
    | [%hamlet.propagate_e.auto] -> .)

let second =
  Hamlet.Combinators.catch first ~handler:(fun error ->
    match error with
    | #Errors.b -> recover_b
    | [%hamlet.propagate_e.auto] -> .)
```

The engine resolves `first` before `second` and uses `first`'s output
certificate as `second`'s input evidence. It follows typed value UIDs, not just
AST nesting.

The first marker has no marker predecessor. Starting with the second, each
marker may have at most one proven predecessor. The chain may be arbitrarily
long, and `chain`, `catch`, and supported wrappers may alternate in any order.
Cycles, opaque edges, and a merge of two independently marked predecessors
receive explicit diagnostics.

## Refusal boundary

Automatic elaboration refuses when exact evidence is unavailable, including:

- abstract, hidden, private, fixed, or genuinely open rows;
- parameter-rooted or unresolved row variables;
- unsupported higher-order, mutable, object, or first-class module flows;
- ambiguous structural-to-nominal catalogue mappings;
- partial grouped leaves or unsupported patterns;
- indirect requirement helper calls;
- unmaterializable payloads;
- missing cross-module catalogue support;
- recursive or unsupported marker dependencies.

The fallback is ordinary typed Hamlet code with an explicit `%hamlet.te` or
`%hamlet.ts` universe. Refusal is part of the proof model, not a degraded
automatic mode.

Before accepting a new evidence path, tests must show that:

1. hidden leaves cannot exist;
2. declaration identities are stable across compiler and Merlin paths;
3. every input atom maps to one complete materializable leaf;
4. guards and partial control flow cannot reach a missing generated case;
5. recovery effects are measured before handler widening;
6. dependent markers receive complete two-channel certificates;
7. final refutations and constraints recheck the proof;
8. no probe scaffolding or internal attribute reaches the final AST;
9. failure points to the responsible marker and names the explicit fallback.
