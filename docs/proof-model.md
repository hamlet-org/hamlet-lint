# Proof model

Hamlet Subtractor generates a forwarding branch only after proving the complete
input universe at that source location. “The type appears compatible” is not
enough: the proof must identify every leaf and show how it can be emitted as
ordinary OCaml.

## Core values

The compiler-independent core represents:

- `Kind`: errors or service requirements;
- `Identity`: the declaration that owns a named leaf;
- `Atom`: one polymorphic-variant tag and its payload shape;
- `Leaf`: one complete named or structural effect;
- `Proof`: a finite set of leaves for one channel;
- `Effect_certificate`: error and requirement proofs for one computation;
- `Residual`: the result of classifying and subtracting handler arms;
- `Generic_contract`: symbolic inputs, transformations, marker slots, and
  outputs for an annotated helper.

These values are immutable. Compiler environments and Typedtree nodes are
converted at the resolver boundary and never enter the subtraction engine.

## Identity and shape

Printed names are ambiguous. Two modules may both export `Errors.timeout`, and
a local value may be called `fail`. The resolver instead checks resolved paths,
declaration UIDs, interface digests, and the attributes emitted by `ppx_hamlet`.

A normalized atom records:

- its channel;
- the declaration identity;
- its variant label;
- whether it has a payload;
- the normalized payload type when present.

Payload normalization preserves nominal type constructors and their arguments.
Two tags with the same label but different payload types are not interchangeable.

## Leaves and materialization

A leaf is not only a name. It also records how final code can match it:

- `Direct`: a complete named row alias matched with `#Path.type`;
- `Structural_variant`: a single visible polymorphic-variant tag;
- `Error_cases`: one field of a generated cross-module error catalogue;
- `Requirement_tag`: a verified generated `Service.Tag.r`;
- `Unavailable`: known evidence that cannot safely be materialized here.

Subtraction may be mathematically possible while code generation is not. An
unavailable leaf therefore causes refusal rather than an invented pattern.

## Sources of exact evidence

### Closed row

A visibly closed row is finite:

```ocaml
let source : (unit, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t = effect
```

The resolver enumerates both tags and normalizes their payloads.

### Explicit Hamlet boundary

`%hamlet.te` and `%hamlet.ts` state a deliberate error or requirement universe.
They are useful where an API intentionally hides its implementation.

### Independently generalized value

Consider:

```ocaml
let build () = Hamlet.Combinators.fail `Missing
```

The type of `build` is polymorphic, so each call gets its own fresh instance.
For `build ()`, the resolver tests only that instance: can `` `Missing `` be
treated as the complete error row without also deciding the type of some
argument or surrounding value? Here the answer is yes, because the error is
created inside `build`.

The test is refused if closing the row would also constrain an argument,
callback, object, mutable cell, or surrounding binding. In that case the
environment, rather than `build`, chooses the errors, so the resolver cannot
claim a complete list locally.

For example, this row is controlled by the caller and cannot be closed locally:

```ocaml
let build error = Hamlet.Combinators.fail error
```

### Traced concrete computation

The resolver also follows a bounded language of verified Hamlet construction:

```ocaml
let build () =
  let open Hamlet.Combinators in
  let* (module Logger) = Logger.Tag.summon in
  let* () = Logger.log "start" in
  fail `Missing
```

It verifies the generated summon, the package type inserted by `ppx_hamlet`,
and calls made through that exact local service module. This is targeted
analysis, not arbitrary whole-program interpretation.

### Earlier marker or generic contract

The output of a resolved marker is a new exact certificate. Later markers may
use it after supported operations add, remove, or replace effects. A generic
helper exports the same relationships symbolically and the caller instantiates
them with its concrete certificate.

## Handler classification

Every preceding handler arm is classified as one of these actions:

- definitely handled;
- explicitly forwarded;
- guarded, therefore possibly handled and still forwarded;
- unsupported.

For errors, `Hamlet.Combinators.fail` forwards the matched value. For
requirements, `Tag.need` or `Dispatch.need` forwards it. A recovery or provider
expression is analyzed for effects it introduces.

Only complete leaves may be subtracted. A wildcard, partial payload pattern,
or user-written or-pattern does not prove which complete declaration it covers.

## Residual equations

For input proof `I`, definitely handled leaves `H`, and effects introduced by
handled branches `R`:

```text
forwarded = I - H
output = forwarded union R
```

Explicitly forwarded and guarded leaves remain in `forwarded`. Claimed leaves
are recorded separately because they determine which callback a generic
dispatcher invokes.

The two channels are evaluated independently and then recombined. Thus:

```text
catch output errors       = input errors - handled errors + recovery errors
catch output requirements = input requirements + recovery requirements

provide output errors       = input errors + provider errors
provide output requirements = input requirements - supplied requirements
                              + provider requirements
```

The actual implementation retains origin information and validates that every
subtracted leaf belongs to the input universe.

## Cross-module catalogues

A generated error union can hide which named aliases formed it once only its
`.cmi` is visible. `[@@rest_cross_cu]` generates `Errors.Cases`, a checked list
of the union's fields and their declaration identities. A downstream resolver
uses that catalogue to reconstruct complete leaves and the generator uses its
dispatcher to emit one linear match.

Service tags already contain a generated identity, key, and witness type, so
they do not need an error catalogue.

## Generic symbolic contracts

A generic helper is compiled before its caller chooses the input rows. Its
contract therefore contains expressions such as:

```text
slot 0 input  = input.errors
slot 0 output = catch(slot 0 input, handled Missing, recovery Recovery)
slot 1 input  = slot 0 output.errors union introduced.errors
helper output = slot 1 output
```

At a concrete call, the resolver substitutes the caller certificate for
`input`, evaluates every slot, and checks each subtraction. It then generates a
typed evidence dispatcher for every slot.

The public slot type is:

```ocaml
type ('input, 'output, 'handled) slot = {
  dispatch :
    'result.
    'input ->
    handled:('handled -> 'result) ->
    forward:('output -> 'result) ->
    'result;
}
```

`'result.` means the dispatcher works for any callback result type. Error
handlers use callbacks returning `Hamlet.t`; requirement handlers use
callbacks returning `Dispatch.t`. Runtime behavior is just an exhaustive match
and one callback invocation.

With multiple markers, the helper receives one tuple argument containing one
slot per marker. Each slot has its own input and output types, so an earlier
slot's output constrains the next slot's input.

Nested helper contracts are composed by substitution. Inner slot IDs are
namespaced, the inner output becomes the source for subsequent outer work, and
all slots are flattened into the outer evidence argument.

## Final checks

The resolver proof is not a replacement type checker. After generation:

- the PPX removes all probe-only attributes and placeholders;
- the compiler or Merlin types the final AST normally;
- generated patterns must be valid for the inferred input type;
- generated forwarding expressions must have the inferred output type;
- the helper's exported evidence argument must agree across `.cmi` boundaries.

Any uncertainty before generation is a refusal. A type error after successful
generation is an implementation bug.

## Refusal boundary

The system refuses open or hidden rows, environment-controlled polymorphism,
unverified aliases, ambiguous control flow, incomplete patterns, missing
catalogues, unsupported compiler modes, and broken generic contracts. The
practical examples and fixes are in [Refused Patterns](./refused-patterns.md).
