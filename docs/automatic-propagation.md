# Automatic propagation

Hamlet Subtractor completes the final branch of an inline `catch` or `provide`
handler. It forwards exactly the effects not claimed by the earlier branches.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

If `source` can fail with `` `Missing | `Timeout ``, the marker becomes a
`` `Timeout `` branch. The PPX stops with an error if it cannot prove that this
is the complete remainder.

## Dune setup

Use the bundled staged PPX in every target that defines or calls automatic
generic helpers, or contains an automatic propagation marker:

```lisp
(preprocess
 (staged_pps hamlet-subtractor.ppx))
```

Do not add `ppx_hamlet` to the same target; the bundle already runs it. The
reason this must be `staged_pps`, rather than `pps`, is explained in
[Compiler and Editor Integration](./integration.md).

## Errors

`[%hamlet.propagate_e.auto]` is the last arm of an inline handler owned by
`Hamlet.Combinators.catch`:

```ocaml
let handled =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return "missing"
    | [%hamlet.propagate_e.auto] -> .)
```

Earlier arms may handle an error or explicitly forward it with
`Hamlet.Combinators.fail`. A guarded arm does not prove that it always handles
its pattern, so the generated forwarding code keeps that leaf.

Recovery code may introduce new effects. They become part of the output row;
they are not mistaken for unhandled input errors.

## Service requirements

`[%hamlet.propagate_s.auto]` is the corresponding final arm of `provide`:

```ocaml
let with_logger =
  Hamlet.Combinators.provide source ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)
```

If `source` requires `Logger` and `Clock`, this handler supplies `Logger` and
forwards `Clock`. `Logger.Tag.need witness` or `Hamlet.Dispatch.need witness`
explicitly forwards a matched requirement.

## Layers

A `Hamlet.Layer.t` has the same two effect channels as `Hamlet.t`: errors while
building the service, and services required by that build. Automatic
propagation can therefore operate on Layer handlers as well.

`Layer.catch` owns an error marker:

```ocaml
let recovered_layer =
  Hamlet.Layer.catch source_layer ~handler:(function
    | `Missing -> fallback_layer
    | [%hamlet.propagate_e.auto] -> .)
```

If `source_layer` can fail with `Missing` or `Timeout`, the generated `Timeout`
branch returns `Layer.fail_like source_layer error`. That Hamlet primitive
keeps the hidden service key while rebuilding the layer as a failure. The PPX
binds `source_layer` once, so a nontrivial source expression is not evaluated a
second time by generated forwarding code.

The user-written `fallback_layer` must provide the same service key as
`source_layer`, as required by `Layer.catch`. Generated forwarding satisfies
that rule automatically through `fail_like`.

The Layer provider family owns requirement markers. Its handler first receives
the service built by `source`, then receives a requirement from the target:

```ocaml
let wired_layer =
  Hamlet.Layer.provide_to_layer
    ~source:logger_layer
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    target_layer
```

The same handler form works with `Layer.provide_to_effect` and
`Layer.provide_merge_to_layer`. The generated residual branches return
`Hamlet.Dispatch.need witness`. Requirements of the source layer are added to
the result after target requirements have been subtracted; they are not
mistaken for requests handled by this callback.

The provider may be an intermediate step between error markers. If its normal
handler exhaustively gives or forwards every exact target requirement, the
resolver preserves an earlier Layer marker's residual errors across the
provider and a later effect marker may continue from them. A handler with
missing or guarded coverage is not considered exhaustive.

The resolver also follows verified direct uses of Layer packaging, recovery,
observation, and unwrapping primitives between markers. The exact supported
forms and safe refusal boundaries are shown in
[Supported Patterns](./supported-patterns.md) and
[Refused Patterns](./refused-patterns.md).

Inside a transparently selected Layer, canonical `try_catch` is exact when its
handler is inline and each branch returns a provable finite error value. Its
requirement proof is empty and its error proof is the union of those branch
results. Named handlers and `try_catch_with_bt` remain refusal boundaries.

A generic helper may take a Layer as its final symbolic input. Only the helper
definition is annotated:

```ocaml
let[@hamlet.generic] recover_missing_layer source =
  Hamlet.Layer.catch source ~handler:(function
    | `Missing -> fallback_layer
    | [%hamlet.propagate_e.auto] -> .)

let recovered = recover_missing_layer concrete_layer
```

The caller writes an ordinary direct call. The PPX specializes the helper's
contract from `concrete_layer` and generates the hidden forwarding evidence.
The same rule covers `Layer.unwrap key (return source)` and
`Layer.unwrap key (success source)`: these forms only wrap and recover the
symbolic Layer, so they preserve its exact caller-supplied proof. An opaque
selector that may return another Layer is refused.

Generic `catch_cause` is also exact when its handler is visible. The operation
removes all typed errors from the symbolic input, preserves its requirements,
and adds the handler result's errors and requirements. A following automatic
marker therefore sees the handler's error row, not the caller's original one.

Generic `scoped_with` peels the fresh scope argument before reading its inline
requirement dispatcher. At a call, an unannotated visible local source can be
proved through the same concrete source language used for marker inputs,
including `add_finalizer` and generated summons. Opaque callback-produced
sources still require a deliberate exact boundary.

## Several markers and intervening operations

Markers may occur in one direct linear flow. `catch` and `provide` may
alternate, and supported Hamlet combinators may appear between them.

```ocaml
source
|> Hamlet.Combinators.catch ~handler:(function
     | `Missing -> Hamlet.Combinators.return ()
     | [%hamlet.propagate_e.auto] -> .)
|> Hamlet.Combinators.chain ~handler:(fun () -> next)
|> Hamlet.Combinators.provide ~handler:(function
     | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
     | [%hamlet.propagate_s.auto] -> .)
|> Hamlet.Combinators.catch ~handler:(function
     | `Timeout -> Hamlet.Combinators.return ()
     | [%hamlet.propagate_e.auto] -> .)
```

The resolver follows the actual data dependency, not just the textual order.
For each marker it starts from the proven output of its predecessors and also
accounts for effects introduced by intervening operations. Supported families
include:

- `chain`, `let*`, `let+`, `and*`, `both`, `map`, and `suspend`;
- `catch`, `catch_cause`, `catch_filter`, and `catch_cause_filter`;
- `map_fail`, `catch_defect`, `tap`, `tap_fail`, `tap_defect`, and `tap_cause`;
- `provide`, `scoped_with`, `scoped`, `or_die`, `thaw`, and `sandbox`;
- `ensuring`, `add_finalizer`, `add_finalizer_exit`, `acquire_release`, and
  `acquire_use_release` where their effect-producing callbacks are visible.

This is a tracing boundary, not a claim that every possible higher-order use of
those functions is accepted. In particular, `sandbox_cause` cannot carry a
generic error row because it maps `'e` to `'e Cause.t`, and manual
`Hamlet.Scope.use` flows require an explicit boundary. See the small examples in
[Supported Patterns](./supported-patterns.md) and
[Refused Patterns](./refused-patterns.md).

## Generic helpers

A normal marker cannot inspect rows chosen later by a caller. An opted-in
generic helper therefore receives caller-generated forwarding evidence for its
final effect or Layer argument.

Definition:

```ocaml
let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
```

Call:

```ocaml
let recovered = recover_missing concrete_source
```

No row annotation is needed when `concrete_source` already has an exact
inferred type. A type annotation is needed only when ordinary OCaml inference
cannot express the intended public row, for example when an API deliberately
widens a computation that currently constructs one error. Only the definition
is annotated:

- `[@hamlet.generic]` changes the exported function type: compiled callers pass
  one final generated evidence argument;
- at a direct call, the caller's PPX recognizes the retained helper contract
  and builds that argument from the concrete source row.

The extra argument exists only in generated OCaml. It is not part of the
source syntax users write.

The helper still has one final generated argument even when its body contains
many markers. With one marker the argument is one evidence slot. With several
markers it is one tuple containing one slot per marker. Each slot describes the
input row at that particular point, what the handler claims, and the row after
forwarding and recovery.

Generic helpers may call earlier generic helpers directly:

```ocaml
let[@hamlet.generic] recover_both source =
  Hamlet.Combinators.catch
    (recover_missing source)
    ~handler:(function
      | `Unavailable -> Hamlet.Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)
```

The outer contract incorporates the inner contract. The caller supplies one
flattened evidence bundle for both helpers; the implementation does not inline
the inner function body.

A caller may continue automatic propagation after a direct generic call. The
resolver retains the instantiated output certificate, so a later `catch` or
`provide` marker starts from the generic helper's exact residual row. For
example, a helper can remove `Missing`, the following marker can remove
`Offline`, and only `Timeout` reaches the last handler:

```ocaml
let after_helper =
  Hamlet.Combinators.catch (recover_missing_to_unit source) ~handler:(function
    | `Offline -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let done_ =
  Hamlet.Combinators.catch after_helper ~handler:(function
    | `Timeout -> Hamlet.Combinators.return ())
```

The direct call needs no special marker or row annotation. The helper
definition remains the only annotated part.

Version-one generic helpers are deliberately regular:

- a named, non-recursive function;
- the last user-written positional parameter is the generic `Hamlet.t` or
  `Hamlet.Layer.t`;
- that parameter follows one supported linear effect flow;
- direct, fully applied helper calls only.

Aliases, partial application, first-class escape, handwritten interfaces that
hide the generated companion, and opaque callbacks are refused.

## Exact input rows

Automatic propagation can proceed from:

- a finite row proved from a supported concrete construction, even when OCaml
  keeps a fresh tail flexible for later unification;
- an explicit `%hamlet.te` or `%hamlet.ts` boundary;
- a finite ordinary type constraint on a named `Layer.t` binding, when the
  declared Layer API is intentionally wider than its visible constructor;
- an imported or independently generalized value whose fresh instance has a
  finite visible row without constraining an argument or surrounding value;
- the proven output of an earlier automatic marker or a direct generic call.

“Independently generalized” means the value owns fresh type variables rather
than borrowing its effect row from an argument, callback, mutable cell, object,
or unknown module. A common accepted example is:

```ocaml
let build () = Hamlet.Combinators.fail `Missing
```

The call `build ()` can be analyzed on its own. By contrast,
`let build error = Hamlet.Combinators.fail error` receives its error universe
from a raw value argument. That function cannot itself use the generic-helper
contract, which specializes a final `Hamlet.t` or `Layer.t` argument. Give the
raw argument a deliberate finite public error type, or put the automatic
handler in a generic helper that receives the completed computation.

## Explicit fallback

Use this form when automatic propagation cannot prove the source row, but you
want to state a fixed, closed error universe yourself. The computation may
come from an API whose construction is not visible, or be a function parameter;
the annotation constrains it to the listed errors rather than making it
generic:

```ocaml
module Errors = struct
  type missing = [ `Missing ]
  type timeout = [ `Timeout ]
end

Hamlet.Combinators.catch computation ~handler:(fun
    (error : [%hamlet.te Errors.missing, Errors.timeout]) ->
  match error with
  | `Missing -> recover ()
  | [%hamlet.propagate_e] -> .)
```

`ppx_hamlet` implements both `[%hamlet.te ...]` and the plain
`[%hamlet.propagate_e]` marker. The annotation expands to a closed error-row
type, and the marker forwards the unhandled members of that declared row.
Subtractor recognizes the closed type as an explicit boundary.

`[%hamlet.propagate_e.auto]`, by contrast, belongs to
`hamlet-subtractor.ppx`: it obtains the row from compiler evidence and
generates the ordinary forwarding arms before the final Hamlet expansion. The
requirement equivalents are `[%hamlet.ts ...]` and
`[%hamlet.propagate_s]` for `ppx_hamlet`, and `[%hamlet.propagate_s.auto]` for
Subtractor.

This is different from `let[@hamlet.generic]`: a generic helper leaves its
input row to the caller and receives generated evidence for that row. An
explicit `[%hamlet.te ...]` annotation fixes the row to the errors named in the
annotation. It cannot reveal a type that another module has made abstract or
private; resolve or translate that error inside the module, or export a usable
finite error type.

## Cross-module generated errors

`[@@rest_cross_cu]` is required only on a generated service declaration whose
named error types will be automatically propagated in another compilation
unit:

```ocaml
[%%hamlet.service
module type Storage = sig
  type read_error = [ `Read_error of string ]

  val read :
    string -> (string, [> read_error ], 'requirements) Hamlet.t
end
[@@rest_cross_cu]]
```

It generates a checked `Errors.Cases` catalogue so a downstream PPX can turn
the imported error union back into complete named leaves. It is not required
for:

- service requirement tags;
- automatic propagation within the same compilation unit;
- services whose errors are never automatically propagated downstream.

The rule is the same when those errors occur while building a `Layer.t`: the
catalogue belongs to the generated error declarations, not to the effect or
Layer container that carries them.

The module that declares the service may use ordinary `(pps ppx_hamlet)` if it
contains no subtractor features. Only targets containing automatic markers or
generic helper definitions/calls need `staged_pps hamlet-subtractor.ppx`.

Continue with [Supported Patterns](./supported-patterns.md) for accepted forms,
or [Architecture](./architecture.md) for the implementation flow.
