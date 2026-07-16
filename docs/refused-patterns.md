# Refused patterns

Hamlet Subtractor refuses when it cannot prove a finite input, a complete
handler partition, or a direct effect dependency. It never adds a best-effort
wildcard.

Each section shows one refused form and the smallest usual fix.

## Abstract, private, or hidden row

An implementation may know the variants while the current compilation unit
only sees an abstract type:

```ocaml
module Source : sig
  type error
  val value : (unit, error, Hamlet.never) Hamlet.t
end
```

Fix: export a usable finite error type when callers need to propagate those
errors automatically. Otherwise, resolve or translate every internal error
before it crosses the abstraction boundary:

```ocaml
module Source = struct
  module Errors = struct
    type missing = [ `Missing ]
    type timeout = [ `Timeout ]
  end

  let value retry =
    if retry then Hamlet.Combinators.fail `Timeout
    else Hamlet.Combinators.fail `Missing

  let handled_inside_source retry =
    Hamlet.Combinators.catch (value retry) ~handler:(function
      | `Missing -> Hamlet.Combinators.return ()
      | `Timeout -> Hamlet.Combinators.return ())
end
```

Here the exported result has no typed errors, so callers have nothing left to
propagate. A producer may instead translate its internal errors to a separate,
exported public error type. An explicit `[%hamlet.te ...]` boundary is useful
only while the variants are visible; it cannot make an already abstract
`Source.error` usable outside `Source`.

## Row chosen by an error argument

Here the caller chooses the raw error value, so the result row depends on a
function argument:

```ocaml
let build error = Hamlet.Combinators.fail error
```

`[@hamlet.generic]` does not apply to this function: `error` is a raw value,
not the final `Hamlet.t` or `Hamlet.Layer.t` parameter that generic helpers
specialize.

If `build` is meant to accept a fixed set of errors, make that set part of its
own API:

```ocaml
module Errors = struct
  type error = [ `Missing | `Timeout ]
end

let build (error : Errors.error) = Hamlet.Combinators.fail error
```

The named type is a real contract of `build`, so the resolver can use it as a
finite universe. If `build` is intentionally polymorphic in its error value,
keep an automatic marker out of that function and place it where the error is
concrete. The next section covers the different case where the caller supplies
an entire `Hamlet.t` computation or `Hamlet.Layer.t`; that case can use
`[@hamlet.generic]`.

The same rule applies to a Layer built from a caller-chosen error:

```ocaml
let failing_layer error = Hamlet.Layer.fail_like template_layer error
```

Use a named finite error type for `error`, or call `fail_like` where the error
constructor is concrete.

## Effect or Layer passed as a parameter

``[> `Missing ]`` is not itself a refusal. It is also the normal inferred shape
of this concrete expression, which the resolver accepts because it can follow
the `fail` call:

```ocaml
let source = Hamlet.Combinators.fail `Missing
```

The problem is an unknown origin. In this ordinary helper, the caller chooses
what `source` contains, so the resolver cannot determine the complete row when
it compiles the helper:

```ocaml
let handle source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)
```

Fix:

```ocaml
let[@hamlet.generic] handle source =
  Hamlet.Combinators.catch source ~handler:(function
    | `Missing -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let result = handle concrete_source
```

## Callback-controlled effect

The callback may return a different row at every call site:

```ocaml
let build callback = callback ()
```

Fix: call a concrete independently generalized function, or move the automatic
marker to a point where the callback result has an explicit exact type.

## Mutable source

The current cell contents control the effect:

```ocaml
let current = ref source
let build () = !current
```

Fix: pass or bind a concrete exact value outside the mutable lookup, then put
the marker at that boundary.

## Object method source

The object's hidden implementation controls the row:

```ocaml
let build object_ = object_#source
```

Fix: expose an exact Hamlet value or a closed named row from the object API.

## Unverified first-class module

The resolver cannot assume that an arbitrary module argument came from the
matching generated service summon:

```ocaml
let build (module Service : SERVICE) = Service.run ()
```

Fix: use a module obtained directly from `Service.Tag.summon`, retaining the
package type inserted by `ppx_hamlet`, or expose an exact result at the module
boundary.

## Indirect combinator alias

Printed names are not trusted:

```ocaml
let emit = Hamlet.Combinators.fail
let source = emit `Missing
```

Fix: call the verified primitive directly:

```ocaml
let source = Hamlet.Combinators.fail `Missing
```

## Opaque higher-order composition

The resolver follows known Hamlet primitives, not arbitrary wrappers:

```ocaml
let apply_twice f source = f (f source)
```

Fix: write the supported Hamlet composition directly, create a supported
generic-helper contract, or add one explicit exact boundary after the wrapper.

## Named handler

The marker must be inside the handler attached to the owner call:

```ocaml
let handler = function
  | `Missing -> recover ()
  | [%hamlet.propagate_e.auto] -> .

let result = Hamlet.Combinators.catch source ~handler
```

Fix: keep the handler inline. This lets the PPX link the owner, input, patterns,
and marker without guessing which calls share the named function.

## Wildcard before the marker

A wildcard already consumes the whole input:

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | _ -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

Fix: remove the redundant marker or replace the wildcard with complete named
arms.

## User-written or-pattern

This syntax does not identify complete declaration leaves:

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | (`Missing | `Timeout) -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

Fix: write separate arms, or match a generated complete named alias:

```ocaml
| `Missing -> recover ()
| `Timeout -> recover ()
| [%hamlet.propagate_e.auto] -> .
```

## Partial payload pattern

A pattern that intentionally covers only part of a payload space is not a
complete leaf proof:

```ocaml
| `Status 404 -> recover ()
| [%hamlet.propagate_e.auto] -> .
```

Fix: bind the complete payload:

```ocaml
| `Status code -> recover code
| [%hamlet.propagate_e.auto] -> .
```

## Unsupported handler control flow

The marker must be the final case of an inline `fun` or `function`, not hidden
inside unrelated control flow:

```ocaml
~handler:(fun error ->
  if enabled then recover error
  else match error with
       | [%hamlet.propagate_e.auto] -> .)
```

Fix: put concrete cases and the final marker in one direct match. Guards on
individual cases are supported.

## Typed-error marker in a cause or defect Layer handler

`propagate_e.auto` forwards values from a typed error row. These handlers
receive a different value:

```ocaml
Hamlet.Layer.catch_cause layer ~handler:(function
  | [%hamlet.propagate_e.auto] -> .)
```

`Layer.catch_cause` receives an `error Hamlet.Cause.t`, and
`Layer.catch_defect` receives a `Hamlet.Die.t`. A generated typed-error branch
would have the wrong input type and could lose cause information.

Fix: use `Layer.catch` when the handler is meant to select typed errors:

```ocaml
Hamlet.Layer.catch layer ~handler:(function
  | `Missing -> fallback_layer
  | [%hamlet.propagate_e.auto] -> .)
```

Otherwise match the cause or defect explicitly and return a same-key fallback
layer yourself.

## Error marker inside `Layer.tap_fail`

`Layer.tap_fail` observes a typed build failure; it does not handle or subtract
that failure from the Layer. The original error is emitted again after a
successful tap callback, so treating the callback as a `catch` owner would
produce the wrong residual proof:

```ocaml
Hamlet.Layer.tap_fail layer ~f:(function
  | `Missing -> record_missing ()
  | [%hamlet.propagate_e.auto] -> .)
```

Fix: write the observer's remaining behavior explicitly. A no-op branch keeps
the original Layer failure unchanged:

```ocaml
Hamlet.Layer.tap_fail layer ~f:(function
  | `Missing -> record_missing ()
  | _ -> Hamlet.Combinators.return ())
```

`tap`, `tap_defect`, and `tap_cause` are also traced transformations rather
than automatic-marker owners. Their callback inputs are a built service, a
defect, or a complete cause, not the Layer's typed-error row.

## Opaque layer returned by `Layer.unwrap`

`Layer.unwrap` runs one effect to obtain a layer and then runs that layer's
build. An ordinary helper cannot prove the second stage when its caller chooses
the returned layer:

```ocaml
let handle selected =
  Hamlet.Layer.unwrap Service.Tag.key
    (Hamlet.Combinators.return selected)
  |> Hamlet.Layer.catch ~handler:(function
       | `Missing -> fallback_layer
       | [%hamlet.propagate_e.auto] -> .)
```

`selected` is a function parameter. Its Layer build may introduce any errors
or requirements allowed by the parameter's type, so the resolver has no finite
construction to inspect at the helper definition.

Fix: apply `Layer.unwrap` where the concrete layer is known:

```ocaml
let layer =
  Hamlet.Layer.unwrap Service.Tag.key
    (Hamlet.Combinators.return fallback_layer)
```

A visible local selector such as `let choose () = return fallback_layer` is
also supported. If the Layer itself is the helper's final symbolic argument,
the direct transparent form may instead be generic:

```ocaml
let[@hamlet.generic] handle selected =
  Hamlet.Layer.unwrap Service.Tag.key
    (Hamlet.Combinators.return selected)
  |> Hamlet.Layer.catch ~handler:(function
       | `Missing -> fallback_layer
       | [%hamlet.propagate_e.auto] -> .)
```

This works because the selector returns `selected` unchanged. A callback,
alias, or other opaque computation that chooses a different Layer remains
refused. Do not add an annotation that claims rows the implementation does not
guarantee.

## Indirect `give` or `need`

The action of a requirement arm must be visible:

```ocaml
let supply witness = Logger.Tag.give witness logger

Hamlet.Combinators.provide source ~handler:(function
  | #Logger.Tag.r as witness -> supply witness
  | [%hamlet.propagate_s.auto] -> .)
```

Fix: write `Logger.Tag.give witness logger`, `Logger.Tag.need witness`, or
`Hamlet.Dispatch.need witness` directly in the arm.

## Grouped requirement alias

A single `#Alias` arm that contains several service tags does not say which
service implementation should be supplied:

```ocaml
type services = [ Logger.Tag.r | Clock.Tag.r ]

| #services as witness -> provide_something witness
```

Fix: write one generated tag arm per service.

## Missing cross-module error catalogue

A downstream compilation unit sees a generated error union but cannot recover
its complete named members:

```ocaml
[%%hamlet.service
module type Storage = sig
  type missing = [ `Missing ]
  val read : unit -> (unit, [> missing ], 'r) Hamlet.t
end]
```

Fix: add `[@@rest_cross_cu]` to this service declaration only when downstream
automatic error propagation needs it. It is not a general requirement for all
services and is never needed merely to forward service requirements.

## Marker is not last

Later user cases would overlap generated forwarding cases:

```ocaml
| `Missing -> recover ()
| [%hamlet.propagate_e.auto] -> .
| `Timeout -> retry ()
```

Fix: move the marker to the final arm.

## Marker body is not `.`

The extension marks a refutation branch, not an expression placeholder:

```ocaml
| [%hamlet.propagate_e.auto] -> Hamlet.Combinators.return ()
```

Fix:

```ocaml
| [%hamlet.propagate_e.auto] -> .
```

## Two independent predecessors

The marker cannot guess which unrelated automatic output should be its source:

```ocaml
let left = first_auto_source ()
let right = second_auto_source ()
let combined = choose left right
```

Fix: use a supported direct composition such as `both`, or introduce one exact
boundary for `combined`. A direct linear marker flow is supported; this refusal
is about ambiguity, not its length.

The same rule applies when a Layer provider's target and source depend on two
different earlier markers. One marker may cross the provider together with a
concrete source or target, but two independent predecessor certificates are
refused until the program introduces one unambiguous exact boundary.

## Invalid generic-helper definition

The first version refuses recursive, anonymous, non-function, and non-linear
definitions:

```ocaml
let[@hamlet.generic] rec loop source = loop source
```

It also refuses using the generic source twice:

```ocaml
let[@hamlet.generic] duplicate source =
  Hamlet.Combinators.both source source
```

Fix: keep one named non-recursive helper with one linear source flow.

## Invalid generic-helper call

The specialization must be direct and fully applied:

```ocaml
let alias = recover_missing
let result = alias source
```

Partial application and pipeline specialization are also refused.

Fix:

```ocaml
let result = recover_missing source
```

The call must name the annotated helper itself. An alias exposes only the
transformed function type; it does not carry the companion contract that tells
the caller how to construct evidence.

## Hidden generic contract in a handwritten interface

An inferred `.mli` includes the generated companion contract. A handwritten
`.mli` that exposes only the helper value hides it:

```ocaml
val recover_missing : ...
```

Fix: omit the handwritten interface for that helper module in version one, or
keep the helper private to the compilation unit. Repeating the definition
annotation on a `val` cannot reconstruct the symbolic body.

## Recursive nested generic contracts

Generic helpers may call earlier helpers, but their symbolic contract graph
must be acyclic. Recursive or mutually recursive helper contracts are refused.

Fix: break the cycle with a concrete exact operation or move the recursive
portion outside automatic generic propagation.

## `sandbox_cause` as a generic error source

`sandbox_cause` changes an arbitrary caller error type `'e` into
`'e Hamlet.Cause.t`:

```ocaml
let[@hamlet.generic] inspect source =
  Hamlet.Combinators.catch
    (Hamlet.Combinators.sandbox_cause source)
    ~handler:(function
      | [%hamlet.propagate_e.auto] -> .)
```

The current symbolic contract can preserve its requirements but cannot express
that type-level error mapping exactly, so this generic error flow is refused.

Fix: use `sandbox` when the whole cause should become a success value, or place
an explicit error universe after `sandbox_cause`.

## Manual scope carriers

`Hamlet.Scope.use` and `Hamlet.Scope.use_with` are manual lifecycle operations,
not `Hamlet.Combinators` source transformations, so a generic source cannot
flow through them automatically:

```ocaml
let[@hamlet.generic] use_existing scope source =
  Hamlet.Scope.use scope source
```

Fix: use `Combinators.scoped` or `scoped_with` when their lifetime fits, or put
an explicit row boundary after the manual scope operation.

## Unsupported compiler mode

The resolver can reproduce only compiler settings reported through the PPX
context. A nondefault typing mode that is not reported is refused.

Fix: use the ordinary supported compiler mode or place an explicit
`%hamlet.te`/`%hamlet.ts` boundary at the affected computation.

## Redundant exhausted marker

When all input leaves are already handled, OCaml warning 11 remains visible:

```ocaml
Hamlet.Combinators.catch source ~handler:(function
  | `Only_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

Fix: remove the marker unless the exhausted branch is an intentional assertion.
