# Generic automatic-propagation helpers

## Status

This document is a design and implementation plan. None of the syntax or
runtime contracts below is implemented yet.

The recommended architecture is caller-supplied forwarding evidence plus an
exported symbolic helper contract. General source inlining is not the primary
design.

Compiler-backed spikes on OCaml 5.5 have resolved the two initial architecture
questions:

- inferred value-binding attributes do not survive as attributes on the
  exported value in the `.cmi`; a generated companion type or module
  declaration is required;
- a plain residual forwarding function is not typable, but an exhaustive
  caller dispatcher is. The dispatcher compiled for two sequential error
  slots, a mixed error/requirement bundle, and a real generated service tag.

The remaining work is implementation. The proposed user syntax and contract
encoding are still provisional.

## Validated compiler results

### Metadata in compiled interfaces

The spike compiled attributed declarations, read their `.cmi` files through
both `Cmi_format` and `Env`, and compared the resulting interface digests.

- Attributes on `let` bindings and expressions are present in the parsed and
  typed implementation but absent from an inferred value description in the
  `.cmi`.
- An attribute written on a `val` in an explicit `.mli` is retained in
  `Types.value_description.val_attributes`.
- Attributes on generated type and module declarations are retained when the
  interface is inferred from the `.ml`.
- Changing a retained contract attribute changes the `.cmi` digest.
- If a handwritten `.mli` omits the generated companion declaration, the
  implementation declaration is hidden from consumers.

The contract will therefore live on a reserved companion declaration in the
inferred interface, not on the helper value itself. The payload must identify
the helper value and include the contract schema and digest. A caller verifies
both the resolved helper UID/type and that companion payload.

Version one will refuse cross-module generic helpers hidden by handwritten
`.mli` files. Supporting them later requires an explicit interface-level
contract representation; merely repeating `[@@hamlet.generic]` on a `val`
cannot reconstruct the symbolic body plan.

### Evidence type

OCaml does not narrow the fallback variable in this generic handler to the
unknown residual row:

```ocaml
function
| `Missing message -> recover message
| error -> forward error
```

The inferred domain of `forward` is the complete input row, including
`Missing`. A function accepting only the residual row is rejected. Refutation
branches cannot repair this because the helper does not know the caller's
complete row.

The validated representation is an exhaustive caller dispatcher:

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

The only unusual syntax is `'result.`. It means that `dispatch` is independent
of what the two callbacks return. For `catch`, both callbacks return a
`Hamlet.t`; for `provide`, they return a `Dispatch.t`. This result-polymorphic
record field is often called “rank-2,” but the runtime behavior is only an
ordinary exhaustive `match` followed by one callback call.

The generated caller dispatcher enumerates its concrete input. It sends leaves
claimed by the helper contract to `handled` and sends every proven forwarding
leaf to `forward`. The helper supplies its original handler cases as the
`handled` callback and `fail` or `Dispatch.need` as `forward`.

`'output` is the handler's final output row, not merely the mathematical
residual. This permits handled branches to add recovery errors or requirements.
The symbolic contract still records the exact residual separately, and the
generated dispatcher is responsible for forwarding only those residual leaves.

A tuple of these slots compiled for two sequential catches without unsafe
casts, existentials, or a generated bundle type. The same dispatcher shape
compiled for `provide` with an actual `ppx_hamlet`-generated `Logger.Tag.r`, and
a record containing one error slot plus one requirement slot preserved both
channels.

The fully generic two-catch spike inferred the essential relationship:

```ocaml
val generic_two_catches :
  (unit, 'input, 'requirements) Hamlet.t ->
  ('input,
   [> `Introduced | `Recovery ] as 'middle,
   [< `Missing ]) slot
  * ('middle, 'output, [< `Introduced ]) slot ->
  (unit, 'output, 'requirements) Hamlet.t
```

The caller instantiated the same helper with closed input, middle, and output
rows. This confirms that recovery and later `chain` contributions can constrain
the symbolic middle row while the caller still chooses the otherwise unknown
residual leaves.

## Goal

Allow a reusable function to accept a Hamlet computation whose error and
requirement rows are chosen by its caller, while still using automatic
propagation inside the function.

For example, the helper should be definable once:

```ocaml
let[@hamlet.generic] recover_missing config source =
  source
  |> Hamlet.Combinators.chain ~handler:(prepare config)
  |> Hamlet.Combinators.catch ~handler:(function
       | #Storage.Errors.missing -> recover config
       | [%hamlet.propagate_e.auto] -> .)
```

Different callers should then instantiate it with different exact rows:

```ocaml
let first =
  recover_missing config first_source [%hamlet.forward.auto]

let second =
  recover_missing config second_source [%hamlet.forward.auto]
```

The final `[%hamlet.forward.auto]` is an explicit call-site request. The caller
knows the concrete type of `first_source` or `second_source`; the PPX uses that
type to generate the forwarding evidence required by the already compiled
helper.

## Why current automatic propagation refuses this

A normal automatic marker is elaborated when the function containing it is
compiled. In a generic helper, the input row belongs to a function parameter:

```ocaml
let handle source =
  Hamlet.Combinators.catch source ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

At that point there is no finite error universe to enumerate. A later caller
may pass any row allowed by the function type, but the helper's module has
already been compiled and its body is no longer available to the caller.

The design must therefore preserve all of these properties:

- the helper is compiled once and remains parametrically typed;
- the caller supplies evidence for its concrete row;
- cross-module calls work from `.cmi` information alone;
- the final compiler and Merlin still type ordinary generated OCaml;
- missing or opaque evidence is refused instead of guessed;
- no helper body is silently copied into callers.

## Recommended public contract

### Definition annotation

The helper opts in explicitly:

```ocaml
let[@hamlet.generic] helper ordinary_arguments source =
  ...
```

Version-one restrictions:

- the binding is a named, non-recursive function;
- the last user-written positional parameter is the input `Hamlet.t`;
- the input effect is used linearly by the supported source-plan language;
- every generic automatic marker belongs to that input's symbolic flow;
- the function is called directly and fully applied;
- partial application, aliases, first-class escape, and indirect calls are
  refused at automatic call sites.

The last-argument convention avoids an additional annotation that names the
effect parameter. A later version may support an explicit parameter selector
if real APIs need a different order.

### Explicit caller argument

The caller supplies one final extension expression:

```ocaml
helper ordinary_arguments concrete_source [%hamlet.forward.auto]
```

This is preferable to silently injecting an argument into every apparent call:

- the syntax pass has a stable place to attach probe metadata;
- an untyped PPX does not need to discover cross-module helper identities
  before constructing a type-safe probe;
- users can see that the call requires specialization;
- code not processed by Hamlet Subtractor does not silently receive different
  behavior;
- missing PPX setup produces an error at an explicit source construct.

The exact extension and annotation names are open decisions. Their semantics,
not their spelling, should be fixed first.

Every compilation unit that defines a generic helper or uses
`[%hamlet.forward.auto]` must run `hamlet-subtractor.ppx` through
`staged_pps`. A producer that merely constructs a computation and never uses
either construct can continue to use ordinary `pps ppx_hamlet`.

### Transformed function type

The definition PPX appends one compiler-generated evidence parameter after the
last user parameter. Conceptually, a one-marker error helper becomes:

```ocaml
val helper :
  config ->
  ('a, 'input_errors, 'input_requirements) Hamlet.t ->
  ('input_errors, 'output_errors, 'handled_errors)
    Hamlet_subtractor.Evidence.slot ->
  ('b, 'output_errors, 'output_requirements) Hamlet.t
```

For a requirement marker, the forwarding slot is conceptually:

```ocaml
('input_requirements, 'output_requirements, 'provided_requirements)
  Hamlet_subtractor.Evidence.slot
```

The result-polymorphic `dispatch` field can return either a Hamlet computation
or a `Dispatch.t`, so the same compiler-independent type serves both channels.
The extra parameter is mandatory and is part of the exported OCaml type. This
is the transformed ABI: separately compiled callers must agree that the
parameter exists.

For multiple generic markers, the final evidence argument is a tuple containing
one typed slot per marker in dependency order. The compiler spike validated two
sequential slots, so version one does not need generated nominal bundle types.

## Definition-site elaboration

The definition PPX performs the following work.

1. Find `[@hamlet.generic]` bindings and validate the supported function shape.
2. Identify the last user parameter and prove that its type is a Hamlet effect.
3. Find automatic markers whose upstream depends symbolically on that
   parameter.
4. Build a symbolic two-channel source plan for the function body.
5. Assign a stable slot ID to every generic marker.
6. Append the generated evidence parameter or bundle to the function.
7. Replace each generic automatic handler with a dispatch through its evidence
   slot.
8. Export a versioned helper contract through the compiled interface.
9. Remove all definition-only linkage attributes from the final AST.

An error handler is rewritten conceptually as:

```ocaml
fun error ->
  __hamlet_slot_0.dispatch error
    ~handled:(function
      | #Storage.Errors.missing -> recover config)
    ~forward:Hamlet.Combinators.fail
```

A requirement handler uses the same shape:

```ocaml
fun requirement ->
  __hamlet_slot_1.dispatch requirement
    ~handled:(function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger)
    ~forward:Hamlet.Dispatch.need
```

The helper then type-checks generically because the unknown forwarding behavior
is represented by an ordinary typed parameter.

The final compiler remains authoritative. The rewritten helper body and its
evidence-parameter type must type-check normally; a symbolic contract is never
accepted as a substitute for that check.

## Non-goals for the first version

Version one does not attempt to support:

- an unannotated function whose public type changes invisibly;
- arbitrary higher-order functions that accept or return generic helpers;
- more than one independent symbolic effect parameter;
- partial application or storage of a generic helper as a first-class value;
- recursive or mutually recursive generic helpers;
- runtime inspection of polymorphic-variant rows;
- source-body export or cross-module inlining;
- opaque callbacks, mutable cells, objects, or first-class modules as sources
  of exact effects without a separate explicit contract.

These are refusal boundaries, not claims that the features are impossible.
Each can be reconsidered after the evidence-passing ABI and symbolic contract
are proven sound.

## Caller-site elaboration

The caller PPX treats `[%hamlet.forward.auto]` as a new probe-owned placeholder.

1. Build a type-safe probe by replacing the placeholder temporarily with a
   bottom expression of the expected evidence-bundle type.
2. Type the probe in the resolver after dependency interfaces are available.
3. Resolve the callee UID and its reserved companion contract in the same
   module.
4. Verify the contract schema, helper fingerprint, source argument position,
   and instantiated Hamlet types.
5. Prove the concrete input error and requirement rows using the existing exact
   evidence rules.
6. Instantiate the helper's symbolic source plan with that concrete
   certificate.
7. Compute the exact input and residual for every evidence slot in dependency
   order.
8. Generate exhaustive dispatcher records for the slots.
9. Replace `[%hamlet.forward.auto]` with the final typed evidence bundle.
10. Add final constraints that correlate the concrete source, evidence bundle,
    and helper result.

No helper body is needed at the call site. The caller uses only the ordinary
function type and the validated contract exported in the callee's `.cmi`.

## Forwarding-slot generation

### Error slot

For a concrete input `Missing | Timeout | Offline`, when the helper handles
`Missing`, the caller generates the equivalent of:

```ocaml
{
  dispatch =
    (fun error ~handled ~forward ->
      match error with
      | `Missing _ as error -> handled error
      | `Timeout _ as error -> forward error
      | `Offline as error -> forward error);
}
```

The helper's `handled` callback contains its original `Missing` arm. Its
`forward` callback is `Hamlet.Combinators.fail`. The slot output row is the
residual plus exact recovery contributions declared by the helper contract.
The caller enumerates the full concrete input, so no generic complement
operation or impossible cast is needed.

When an intermediate computation or forwarded branch has a row narrower than
the contract's proven output union, the generator may insert an ordinary
covariance coercion (`:>`). The spike required this for recovery errors,
requirements introduced by recovery, and effects introduced by a later
`chain`. The proof must establish the inclusion before generation. This is a
typed widening, not `Obj.magic` or an unchecked cast.

### Requirement slot

For a concrete input `Logger | Clock`, when the helper provides `Logger`, the
caller generates the equivalent of:

```ocaml
{
  dispatch =
    (fun requirement ~handled ~forward ->
      match requirement with
      | #Logger.Tag.r as witness -> handled witness
      | #Clock.Tag.r as witness -> forward witness);
}
```

The helper supplies its original provider arm as `handled` and
`Hamlet.Dispatch.need` as `forward`.

Existing named-leaf, structural-variant, service-tag, and `Errors.Cases`
materialization should be reused by the slot generator.

## Symbolic helper contracts

The current resolver source plan contains concrete certificates and earlier
marker IDs. Generic helpers need the same algebra with a symbolic input.

Suggested compiler-independent model:

```ocaml
type input_channel = Input_errors | Input_requirements

type channel_expression =
  | Input of input_channel
  | Exact of Proof.t
  | Union of channel_expression list
  | Subtract of channel_expression * Leaf.t list
  | Replace of channel_expression
  | Clear of Kind.t
  | Opaque of opacity

type slot = {
  id : slot_id;
  kind : Kind.t;
  input : channel_expression;
  handled : Leaf.t list;
  explicitly_forwarded : Leaf.t list;
  recovery : channel_expression;
}

type helper_contract = {
  schema_version : int;
  helper_fingerprint : string;
  effect_parameter : int;
  slots : slot list;
  output_errors : channel_expression;
  output_requirements : channel_expression;
}
```

The final representation should reuse `Effect_certificate`, `Residual`, and
`Proof` operations rather than implementing a second set algebra. The symbolic
layer should describe substitutions; after caller instantiation, evaluation
must produce the existing concrete core values.

The contract must not contain Typedtree nodes, mutable compiler types, or raw
compiler environments. Leaf identities and dependency fingerprints must use
the same normalized representation as current resolver responses.

## Primitive semantics inside a generic helper

The symbolic evaluator should reuse the row equations already implemented for
dependent markers.

| Primitive family | Symbolic operation |
| --- | --- |
| `chain`, `let*`, `both`, `map`, `tap*`, `catch_defect`, `ensuring` | Preserve input channels and union exact contributors |
| `catch`, `catch_cause`, `catch_filter`, `catch_cause_filter` | Replace source errors with recovery errors; preserve source and recovery requirements |
| `provide`, `scoped_with` | Preserve errors and replace requirements with a proven symbolic output |
| `or_die`, `thaw`, `sandbox` | Clear typed errors |
| `scoped` | Clear the scope requirement |
| verified `Tag.summon` | Add its exact service requirement |
| opaque callback or unknown first-class computation | Refuse or require another explicit symbolic input |

The helper body may contain arbitrary pure OCaml. It may contain effectful OCaml
only where every possible returned Hamlet computation has a supported symbolic
origin. “Anything can occur in the body” cannot mean that mutable state,
unknown callbacks, or arbitrary runtime module values become exact evidence.

## Concrete catch and provide inside the helper

A concrete `catch` or `provide` must not reuse the original caller evidence
unchanged. It transforms the symbolic row.

For a concrete catch:

```text
output errors = input errors
                - unguarded handled leaves
                + exact recovery errors

output requirements = input requirements
                      + exact recovery requirements
```

For a concrete provide:

```text
output errors = input errors

output requirements = input requirements
                      - supplied requirements
```

Later generic markers consume these transformed expressions. This is why the
contract needs symbolic subtraction and replacement rather than one forwarding
function copied unchanged through the body.

Guards, explicit `fail` forwarding, `Dispatch.need`, recovery effects, and
opaque opposite-channel evidence must retain their current meanings.

## Calling another generic helper

An annotated generic helper cannot generate concrete evidence when it calls
another generic helper: its own input is still symbolic.

Instead, contract composition should work as follows:

1. Load and validate the inner helper's contract.
2. Derive the symbolic certificate at the inner call site.
3. Substitute that certificate for the inner contract's input nodes.
4. Namespace and append the inner evidence slots to the outer contract.
5. Replace the inner `[%hamlet.forward.auto]` argument with projections from
   the outer evidence bundle.
6. Substitute the inner output expressions into the remainder of the outer
   source plan.

At the final concrete caller, one evidence bundle satisfies both the outer and
inner slots. The helper implementations remain separately compiled and are not
inlined.

Contract dependencies form a graph. Initial support should require an acyclic
graph; recursive generic helpers and mutually recursive contracts should be
refused with a dedicated diagnostic until a sound fixed-point model exists.

## Cross-module metadata

The contract must survive separate compilation and be correlated with the
callee's value description.

Validated direction:

- generate a reserved companion type or module declaration whose retained
  attribute contains the bounded, versioned contract;
- encode the helper name, transformed type fingerprint, contract schema, and
  contract digest in that payload;
- locate the companion in the same resolved module as the helper and verify the
  helper UID and instantiated type before trusting it;
- reject missing, duplicated, malformed, oversized, or unsupported contracts;
- rely on the ordinary `.cmi` digest for dependency invalidation, while also
  returning the contract digest in resolver evidence for correlation.

The compiler spike ruled out attaching the contract only to the inferred
helper value: attributes on an implementation `let` do not appear in that
value's exported `val_attributes`. Generated type and module declaration
attributes do survive and are visible through compiler-libs. Changing their
payload changes the `.cmi` digest.

No contract discovery should search `PATH`, source files, build directories, or
untracked caches. A consumer sees the last contract in the dependency's built
`.cmi`, following the same freshness rules as existing cross-module evidence.

## Interfaces and inferred types

The original generic function must retain a valid ordinary OCaml type. Caller
specialization does not excuse an ill-typed definition.

For inferred interfaces, the transformed implementation naturally exports both
the evidence parameter and companion contract declaration.

Version one refuses a cross-module generic helper hidden behind a handwritten
`.mli`. The interface can repeat the transformed function type, but it cannot
derive the symbolic contract from the absent implementation body. Repeating an
annotation on `val helper` is therefore insufficient. A later version may add
an explicit interface contract form or generated-interface workflow, but it
must verify that the declared contract matches the implementation.

Merlin hover should show a stable, understandable evidence alias where
possible. Hidden arguments must not disappear from compiler types: they are a
real part of the function contract even if documentation renders them more
compactly.

## Why source inlining is not the primary design

Literal or AST-level inlining creates several problems:

- a caller normally has only the callee's `.cmi`, not its implementation AST;
- exporting bodies as metadata couples callers to implementation details;
- body changes would cause broad caller invalidation;
- evaluation order, allocation, local modules, generativity, recursion, source
  locations, warnings, and debugging can change;
- code size grows at every call site;
- the original helper still needs a valid generic inferred type.

A later optimization may specialize a local, non-recursive, non-escaping
helper after the evidence-passing semantics are established. Such
specialization must be observationally equivalent to an ordinary call and must
not become the cross-module correctness mechanism.

## Implementation phases

### Phase 0: compiler and type-system spikes

Completed results:

- inferred value attributes are unsuitable; a companion type or module
  declaration is the `.cmi` carrier;
- changing retained companion metadata changes the `.cmi` digest;
- handwritten `.mli` files are refused in version one unless a complete future
  signature-contract syntax is designed;
- residual-only forwarding functions do not type-check;
- the exhaustive result-polymorphic dispatcher type-checks for error and
  requirement markers;
- two sequential dispatcher slots type-check as a tuple;
- mixed error/requirement dispatchers preserve both channels;
- actual generated service tags type-check through `Tag.give` and
  `Dispatch.need`;
- ordinary covariance coercions are sufficient when a concrete residual branch
  is narrower than the proven output union; no unsafe cast is needed.

Remaining spikes before production implementation:

- verify that a bottom placeholder can make the caller probe type-safe before
  final evidence generation;
- verify direct and pipeline call AST shapes with the explicit final extension;
- choose deterministic companion naming and test collision diagnostics;
- encode, decode, size-limit, and UID-correlate one minimal contract payload;
- test guarded arms and every currently accepted pattern shape through the
  `handled` callback.

Exit criterion: the remaining caller-probe and carrier-correlation fixtures
pass. The evidence representation, metadata carrier, and version-one `.mli`
policy are already decided.

### Phase 1: one generic error marker

Support one non-recursive helper containing one generic automatic error marker.

- Add the definition annotation and explicit caller extension syntax.
- Rewrite the helper with one error-dispatcher parameter.
- Export and validate a one-slot contract.
- Instantiate it from a direct, fully applied call with a closed concrete row.
- Generate the exhaustive dispatcher with existing leaf materialization.
- Preserve exact recovery errors and requirements.
- Add specific diagnostics for unsupported definitions and calls.

Exit criterion: the same compiled helper is called from another module with two
different exact error rows and produces two different precise residual types.

### Phase 2: requirement markers and two-channel certificates

- Add requirement forwarding slots using `Dispatch.need`.
- Preserve exact errors across generic provide.
- Preserve exact requirements introduced by error recovery.
- Support one error slot or one requirement slot in the same contract schema.
- Verify cross-channel sequences at runtime and in Merlin.

Exit criterion: one helper can be instantiated for different service rows and
another helper can forward an error residual plus a recovery requirement.

### Phase 3: symbolic source-plan composition

- Move symbolic contract values into `subtractor/core`.
- Generalize current preserve, replace, clear, and explicit-output source-plan
  operations to accept symbolic inputs.
- Support row-preserving composition around the input parameter.
- Support concrete catch and provide transformations before a later generic
  marker.
- Support several generic markers in one helper with one evidence bundle.
- Refuse two independent symbolic effect parameters in v1.

Exit criterion: an annotated helper may alternate concrete `chain`, `catch`,
and `provide`, and each later generic marker sees the correctly transformed
symbolic row.

### Phase 4: nested generic helpers

- Load inner contracts by verified UID.
- Compose contracts by symbolic substitution.
- Flatten and namespace evidence slots deterministically.
- Detect recursive and mutually recursive contract graphs.
- Correlate all contract and dependency fingerprints in diagnostics.

Exit criterion: a cross-module generic helper may call another generic helper,
and the final concrete caller supplies one generated evidence bundle.

### Phase 5: ergonomics and controlled expansion

- Decide whether safe pipeline syntax should be accepted.
- Add readable public aliases for evidence bundles.
- Consider allowing explicitly selected non-final effect parameters.
- Consider local specialization only as an optimization.
- Revisit recursion and higher-order escape only with a separate soundness
  design.

## Expected file-level changes

The names are provisional, but responsibilities should remain separated.

- `subtractor/core/generic_contract.ml/.mli`: compiler-independent symbolic
  rows, slots, contract validation, substitution, serialization, and digesting.
- a small public runtime module for the result-polymorphic `Evidence.slot`
  type, wired as a PPX runtime dependency so consuming targets do not need a
  surprising manual library stanza; Phase 0 must choose its final
  package/module name.
- `subtractor/core/effect_certificate.ml`: reuse or generalize concrete
  preserve/replace/clear operations for instantiated contracts.
- `subtractor/hamlet_subtractor_probe.ml`: definition and caller placeholders,
  stable slot IDs, and probe links.
- `subtractor/hamlet_subtractor_compiler_evidence.ml`: verify annotated helper
  identities, construct symbolic plans, and instantiate caller contracts.
- `subtractor/hamlet_subtractor_engine.ml`: order slots and contract
  dependencies without retaining compiler values.
- `subtractor/hamlet_subtractor_generator.ml`: generate error and requirement
  dispatchers, proof-backed covariance coercions, and evidence tuples.
- `subtractor/hamlet_subtractor_replace.ml`: rewrite definitions and replace
  caller extensions in the base AST.
- `subtractor/core/protocol.ml/.mli`: versioned contract or slot results if they
  must cross the resolver process separately from existing marker results.
- `subtractor/hamlet_subtractor_ppx.ml`: coordinate the new definition and call
  lifecycle with ordinary Hamlet rewriting.
- `docs/`: public syntax, supported symbolic composition, refusals, `.cmi`
  freshness, and inferred-type examples.
- `test/automatic_propagation/` and
  `subtractor/integration/installed_consumer.sh`: public and installed-package
  acceptance.

The annotation or generated public aliases may also require coordinated changes
in the companion Hamlet/`ppx_hamlet` package. That boundary must be decided in
Phase 0 rather than hidden inside this repository.

## Diagnostics and refusal policy

Add stable, specific categories for at least:

- annotation applied to a non-function or unsupported recursive binding;
- last user parameter is not a Hamlet effect;
- no generic marker depends on the designated input;
- marker depends on more than one symbolic effect parameter;
- missing final `[%hamlet.forward.auto]` argument;
- extension passed to a non-generic function;
- indirect, partial, or first-class helper application;
- malformed, stale, incompatible, or oversized helper contract;
- contract type does not match the instantiated callee type;
- opaque callback or unsupported primitive in symbolic flow;
- recursive generic-helper contract dependency;
- unmaterializable concrete residual at the caller;
- caller target uses an early `pps` phase instead of `staged_pps`.

Every refusal should point to an explicit fallback: give the helper a declared
`%hamlet.te`/`%hamlet.ts` universe, move automatic propagation to the caller,
or split opaque effect construction behind a separately annotated contract.

## Test plan

### Core and protocol

- symbolic input substitution for both channels;
- union, subtraction, replacement, and clearing;
- recovery contributions and opposite-channel opacity;
- deterministic slot ordering and contract digests;
- contract encode/decode round trips and schema mismatch;
- rejection of duplicate slots, cycles, conflicting leaves, and oversized
  metadata.

### Definition rewriting

- inferred helper type contains the evidence parameter;
- inferred `.cmi` contains the correlated companion declaration and contract
  attribute;
- one error marker and one requirement marker;
- recovery effects are reflected in the slot type;
- concrete composition before and after the marker;
- annotation errors, handwritten `.mli`, recursion, multiple input parameters,
  and opaque flows;
- no probe attributes or generic marker extensions survive final output.

### Caller rewriting

- two call sites instantiate one helper with different exact rows;
- exhaustive error and requirement dispatchers contain handled and forwarded
  partitions with no wildcard guess;
- two sequential slots infer precise middle and output rows;
- direct local and cross-module calls;
- closed, independently generalized, structural, named, and catalogue-backed
  inputs;
- saved and unsaved caller changes produce different evidence;
- dependency `.cmi` contract changes invalidate the expansion;
- missing, collided, malformed, and UID-mismatched companion contracts are
  refused;
- partial application, aliases, missing extension, wrong callee, and explicit
  type mismatches are refused.

### Composition

- generic helper calling another generic helper;
- `chain` before and after a generic marker;
- concrete catch replacing errors before another generic marker;
- concrete provide replacing requirements before another generic marker;
- error and requirement markers alternating;
- recovery introducing an error or requirement;
- two independent symbolic inputs refused;
- recursive contract graph refused.

### Public acceptance

- final inferred-type golden;
- final expansion golden;
- runtime behavior for handled and forwarded branches;
- raw Merlin final source and Typedtree;
- saved and unsaved OCaml-LSP hover;
- dependency-interface invalidation;
- negative diagnostic golden;
- cross-module generated errors with `[@@rest_cross_cu]`;
- `make installed-consumer` and `make installed-consumer-keep` using the same
  shared fixture;
- full `make all` and opam packaging checks.

## Performance and limits

- Contract evaluation should be linear in the contract plus concrete leaf
  count after catalogue lookup.
- Contracts and evidence bundles need explicit size and nesting limits.
- Slot IDs and generated order must be deterministic.
- No persistent result cache should be introduced.
- Merlin's optional external PPX cache remains unsupported because helper and
  dependency `.cmi` contents affect caller expansion.
- The caller should type one prepared probe, not one compiler session per slot.

## Definition of done

The feature is complete when all of these are true:

- one separately compiled generic helper accepts at least two different exact
  caller rows without recompiling or inlining its body;
- the helper's ordinary inferred type remains valid and exposes the evidence
  contract honestly;
- caller-generated error and requirement forwarding is exhaustive and contains
  no unsafe cast;
- concrete `chain`, `catch`, and `provide` transformations inside the helper
  produce correct later slot inputs;
- nested generic-helper calls compose through contracts rather than bodies;
- builds, Merlin, and OCaml-LSP agree on exact residual types;
- stale or missing contracts fail closed with actionable diagnostics;
- public docs explain syntax, transformed types, supported composition, and
  refusal boundaries without requiring knowledge of compiler internals;
- the complete normal and installed-consumer gates pass.

## Open decisions

The compiler spikes resolved these decisions:

- use a retained companion type or module declaration, not an inferred value
  attribute;
- use exhaustive result-polymorphic dispatcher slots and a tuple for multiple
  markers;
- use exhaustive caller-owned partitioning rather than residual-only fallback
  functions or impossible branches;
- refuse handwritten `.mli` generic helpers in version one;
- permit only proof-backed covariance coercions, never unsafe casts.

The remaining decisions are:

1. Exact annotation and caller-extension spelling.
2. Companion declaration kind, deterministic naming, collision policy, payload
   serialization, and size limit.
3. Exact bottom-placeholder representation for the caller probe.
4. Whether Phase 1 exposes the final tuple convention immediately, even for one
   slot.
5. Whether direct pipeline syntax is part of version one or deferred.
6. Which annotation and public `Evidence.slot` type belong in `ppx_hamlet`
   versus `hamlet-subtractor`.
7. The future interface-level syntax, if handwritten `.mli` support becomes a
   requirement.

Production implementation should begin with the remaining companion-payload
and caller-probe spikes, then proceed directly to the Phase 1 vertical slice.
