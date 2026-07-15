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

## Several markers and intervening operations

There is no minimum chain length. One marker works; two markers work; longer
linear sequences work. `catch` and `provide` may alternate, and supported
Hamlet combinators may appear between them.

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

- `chain`, `let*`, `and*`, `both`, `map`, and `suspend`;
- `catch`, `catch_cause`, `catch_filter`, and `catch_cause_filter`;
- `map_fail`, `catch_defect`, `tap`, `tap_fail`, `tap_defect`, and `tap_cause`;
- `provide`, `scoped_with`, `scoped`, `or_die`, `thaw`, and `sandbox`;
- `ensuring`, `add_finalizer`, `add_finalizer_exit`, `acquire_release`, and
  `acquire_use_release` where their effect-producing callbacks are visible.

This is a tracing boundary, not a claim that every possible higher-order use of
those functions is accepted. See the small examples in
[Supported Patterns](./supported-patterns.md) and
[Refused Patterns](./refused-patterns.md).

## Generic helpers

A normal marker cannot inspect a row chosen later by a caller. An opted-in
generic helper therefore receives caller-generated forwarding evidence.

Definition:

```ocaml
let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
```

Call:

```ocaml
let recovered = recover_missing concrete_source [%hamlet.forward.auto]
```

No row annotation is needed when `concrete_source` already has an exact
inferred type. The two annotations have different jobs:

- `[@hamlet.generic]` intentionally changes the exported function ABI by
  appending one generated evidence argument;
- `[%hamlet.forward.auto]` asks the caller's PPX to build that argument from
  the concrete source row.

The helper still has one final generated argument even when its body contains
many markers. With one marker the argument is one evidence slot. With several
markers it is one tuple containing one slot per marker. Each slot describes the
input row at that particular point, what the handler claims, and the row after
forwarding and recovery.

Generic helpers may call earlier generic helpers directly:

```ocaml
let[@hamlet.generic] recover_both source =
  Hamlet.Combinators.catch
    (recover_missing source [%hamlet.forward.auto])
    ~handler:(function
      | `Unavailable -> Hamlet.Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)
```

The outer contract incorporates the inner contract. The caller supplies one
flattened evidence bundle for both helpers; the implementation does not inline
the inner function body.

Version-one generic helpers are deliberately regular:

- a named, non-recursive function;
- the last user-written positional parameter is the generic `Hamlet.t`;
- that parameter follows one supported linear effect flow;
- direct, fully applied helper calls only;
- the final call argument is `[%hamlet.forward.auto]`.

Aliases, partial application, first-class escape, handwritten interfaces that
hide the generated companion, and opaque callbacks are refused.

## Exact input rows

Automatic propagation can proceed from:

- a closed inferred row;
- an explicit `%hamlet.te` or `%hamlet.ts` boundary;
- a concrete Hamlet computation the resolver can trace;
- an imported or independently generalized value with a row that can be
  closed without changing types shared with its environment;
- the proven output of an earlier automatic marker or generic-helper contract.

“Independently generalized” means the value owns fresh type variables rather
than borrowing its effect row from an argument, callback, mutable cell, object,
or unknown module. A common accepted example is:

```ocaml
let build () = Hamlet.Combinators.fail `Missing
```

The call `build ()` can be analyzed on its own. By contrast,
`let build error = Hamlet.Combinators.fail error` receives its error universe
from the caller and needs either a generic-helper contract or an explicit row
boundary.

## Explicit fallback

When the row is intentionally abstract, state its universe and use the ordinary
Hamlet marker:

```ocaml
let source = ([%hamlet.te computation] : (unit, errors, requirements) Hamlet.t)

Hamlet.Combinators.catch source ~handler:(function
  | `Missing -> recover ()
  | [%hamlet.propagate_e errors] -> .)
```

The equivalent requirement boundary uses `%hamlet.ts` and
`[%hamlet.propagate_s ...]`.

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

The module that declares the service may use ordinary `(pps ppx_hamlet)` if it
contains no subtractor features. Only targets containing automatic markers or
generic helper definitions/calls need `staged_pps hamlet-subtractor.ppx`.

Continue with [Supported Patterns](./supported-patterns.md) for accepted forms,
or [Architecture](./architecture.md) for the implementation flow.
