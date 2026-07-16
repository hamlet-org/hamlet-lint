# Supported patterns

Each example below is intentionally small. Assume its Dune target uses:

```lisp
(preprocess
 (staged_pps hamlet-subtractor.ppx))
```

## What “exact” means

The PPX does not require you to annotate every effect with a closed row. OCaml
normally keeps rows flexible so later expressions can unify with them; that is
expected and works.

For automatic propagation, “exact” means something narrower: the resolver can
account for every error or requirement introduced by the computation it is
following. For example, it knows that `Hamlet.Combinators.fail \`Missing`
introduces `Missing`, even though OCaml may keep the surrounding row flexible.
It combines such facts as it follows supported calls.

It stops only when part of the computation is genuinely unknown, such as an
opaque API result or a function parameter in an ordinary helper. In that case,
use an explicit Hamlet boundary or make the helper generic.

## Inline error handler

The handler must be written at the `catch` call and the marker must be last.

```ocaml
let result =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
```

If `source` has errors ``[ `Missing | `Timeout ]``, the generated branch
forwards only `` `Timeout ``.

Pipeline syntax is equivalent:

```ocaml
let result =
  source
  |> Hamlet.Combinators.catch ~handler:(function
       | `Missing -> Hamlet.Combinators.return ()
       | [%hamlet.propagate_e.auto] -> .)
```

## Complete named error arm

A `#Path.type` pattern proves that the whole named leaf is handled.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

Payloads inside `read_error` do not have to be repeated because the named row
alias denotes the complete leaf.

## Direct structural error arm

A directly written polymorphic-variant constructor is also complete.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing message -> recover message
  | [%hamlet.propagate_e.auto] -> .)
```

The payload shape is checked against the input row.

## Complete service arm

A generated service tag is matched and supplied directly:

```ocaml
Hamlet.Combinators.provide source ~handler:(function
  | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
  | [%hamlet.propagate_s.auto] -> .)
```

If the input requires `Logger` and `Clock`, only `Clock` is forwarded.

## Explicit forwarding arm

An arm may name a leaf and deliberately keep it in the output.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing as error -> Hamlet.Combinators.fail error
  | [%hamlet.propagate_e.auto] -> .)
```

The requirement equivalent uses the matched witness:

```ocaml
Hamlet.Combinators.provide source ~handler:(function
  | #Logger.Tag.r as witness -> Logger.Tag.need witness
  | [%hamlet.propagate_s.auto] -> .)
```

## Guarded arm

A guard may fail, so the leaf remains in the generated forwarding set.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing when cache_is_ready () -> use_cache ()
  | [%hamlet.propagate_e.auto] -> .)
```

When the guard is false, the generated dispatcher forwards `` `Missing ``.

## Closed inferred row

A normal closed value needs no effect-row annotation.

```ocaml
let source =
  if retry_allowed () then Hamlet.Combinators.fail `Missing
  else Hamlet.Combinators.fail `Timeout

let result =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
```

An ordinary OCaml type annotation is still useful when an API deliberately
exposes a wider row than its implementation constructs. That is an API choice,
not a requirement imposed by the subtractor.

## Independently generalized builder

The builder owns its error row, so a direct call can be analyzed independently.

```ocaml
let build () = Hamlet.Combinators.fail `Missing

let result =
  Hamlet.Combinators.catch (build ()) ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

In practice this marker is redundant because `build ()` has only `Missing` and
there is no preceding arm. Add a real handled arm in production code; the
example only shows that the call itself is traceable.

## Concrete local Hamlet builder

The resolver follows direct construction through supported primitives.

```ocaml
let build () =
  let open Hamlet.Combinators in
  let* value = first_step () in
  map (second_step value) ~f:String.trim
```

At a marker, the resolver combines the exact effects of `first_step` and
`second_step`. It does not require a row annotation when both are themselves
exact.

## Verified summoned service module

`ppx_hamlet` inserts the first-class module package type, and the resolver
verifies that the module came from the matching generated summon.

```ocaml
let build () =
  let open Hamlet.Combinators in
  let* (module Logger) = Logger.Tag.summon in
  let* () = Logger.log "starting" in
  let* (module Clock) = Clock.Tag.summon in
  Clock.now ()
```

Providing `Logger` around `build ()` leaves `Clock` in the requirement row.
The user does not write a package-type annotation.

## Recovery introduces an error

Handled branches may fail with a new error.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing -> Hamlet.Combinators.fail `Recovery_failed
  | [%hamlet.propagate_e.auto] -> .)
```

For input ``[ `Missing | `Timeout ]``, the output is
``[ `Recovery_failed | `Timeout ]``.

## Recovery introduces a requirement

A recovery computation may also request a service.

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Missing -> audit_recovery ()
  | [%hamlet.propagate_e.auto] -> .)
```

Any exact requirements of `audit_recovery ()` are added to the output
requirement channel.

## Catches in sequence

```ocaml
source
|> Hamlet.Combinators.catch ~handler:(function
     | `Missing -> Hamlet.Combinators.return ()
     | [%hamlet.propagate_e.auto] -> .)
|> Hamlet.Combinators.catch ~handler:(function
     | `Timeout -> Hamlet.Combinators.return ()
     | [%hamlet.propagate_e.auto] -> .)
```

Each later marker receives the exact output of its direct predecessor.

## Catch and provide in either order

Error and requirement operations may alternate.

```ocaml
source
|> Hamlet.Combinators.provide ~handler:(function
     | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
     | [%hamlet.propagate_s.auto] -> .)
|> Hamlet.Combinators.catch ~handler:(function
     | `Missing -> Hamlet.Combinators.return ()
     | [%hamlet.propagate_e.auto] -> .)
```

Reversing those two calls is also supported when the resulting types are valid.
Each marker changes only its own channel and incorporates effects introduced by
its handler.

## `chain`, `let*`, `let+`, `and*`, `both`, and `map`

Composition can occur between markers:

```ocaml
let open Hamlet.Combinators in
let* first = initial in
let* second = next first in
return (first, second)
```

The same flow may be written with `chain`. `let+` is Hamlet's mapping syntax:
`ppx_hamlet` rewrites it to `map` before Subtractor analyses the expression.
`and*` and `both` combine the effects of both inputs. `map` preserves the
effect rows of its input.

## Catch filters

Filter primitives are followed when their source and callbacks are visible.

```ocaml
Hamlet.Combinators.catch_filter source
  ~filter:(function `Retryable -> Some () | _ -> None)
  ~handler:(fun () -> retry ())
  ~on_no_match:(fun cause -> Hamlet.Combinators.fail_cause cause)
```

The resolver includes effects from both callback outcomes. The same principle
applies to `catch_cause` and `catch_cause_filter`.

## Mapping and observing failures

The resolver follows supported direct uses of `map_fail`, `catch_defect`,
`tap`, `tap_fail`, `tap_defect`, and `tap_cause`.

```ocaml
let mapped =
  Hamlet.Combinators.map_fail source ~f:(fun _ -> `Mapped)
```

`map_fail` replaces the error channel with its inferred output. Tap-like
operations preserve the source effects and add exact callback effects.

## Scope and resource primitives

Direct visible uses of scope and resource combinators are traced. A bounded
resource lifetime combines the effects of acquire, use, and release:

```ocaml
Hamlet.Combinators.acquire_use_release acquire
  ~use:(fun resource -> use resource)
  ~release:(fun resource exit -> release resource exit)
```

Registering cleanup adds the generated `Scope` requirement as well as the
cleanup computation's own requirements:

```ocaml
Hamlet.Combinators.add_finalizer cleanup
```

The same rule applies to `add_finalizer_exit` and `acquire_release`. The
signature tells OCaml that `Scope` is required, but it does not list the other
requirements. Subtractor recognizes these particular combinators and applies
their known rule: add `Scope` to the requirements proven for their visible
cleanup, acquire, and release computations. If one of those computations is
unknown, the normal exactness rule still applies and the PPX refuses to guess.

`ensuring` combines the source and finalizer effects. `scoped` removes the
`Scope` requirement, while `scoped_with` subtracts whichever requirement arms
its inline handler supplies.

`or_die` and `sandbox` clear the typed-error channel; `thaw` widens a proven
empty error channel. `sandbox_cause` is deliberately more limited because it
changes each arbitrary error type to `Cause.t`; see the refused guide.

## Generic error helper

The concrete caller row is inferred; no row annotation is required.

```ocaml
let[@hamlet.generic] recover_missing source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let result = recover_missing concrete_source
```

## Generic requirement helper

Generic helpers work for `provide` as well:

```ocaml
let[@hamlet.generic] with_logger logger source =
  Hamlet.Combinators.provide source ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s.auto] -> .)

let result = with_logger logger concrete_source
```

The caller-generated slot forwards every concrete requirement other than
`Logger`.

## Several markers in one generic helper

The function still receives one generated evidence argument.

```ocaml
let[@hamlet.generic] prepare logger source =
  source
  |> Hamlet.Combinators.catch ~handler:(function
       | `Missing -> Hamlet.Combinators.return ()
       | [%hamlet.propagate_e.auto] -> .)
  |> Hamlet.Combinators.provide ~handler:(function
       | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
       | [%hamlet.propagate_s.auto] -> .)
```

Internally that argument is a tuple with one typed slot for each marker.

## Nested generic helper

An outer helper may directly call an earlier helper and continue transforming
the result:

```ocaml
let[@hamlet.generic] recover_more source =
  Hamlet.Combinators.catch
    (recover_missing source)
    ~handler:(function
      | `Unavailable -> Hamlet.Combinators.return ()
      | [%hamlet.propagate_e.auto] -> .)
```

The outer contract composes the inner symbolic output and exports one flattened
evidence bundle.

## Cross-module errors with a catalogue

The producing service opts into a downstream error catalogue:

```ocaml
[%%hamlet.service
module type Storage = sig
  type missing = [ `Missing ]
  type timeout = [ `Timeout ]

  val read : string -> (string, [> missing | timeout ], 'r) Hamlet.t
end
[@@rest_cross_cu]]
```

A different compilation unit can then automatically propagate a subset of
`Storage.Errors.error`. Requirement tags do not need this option.
