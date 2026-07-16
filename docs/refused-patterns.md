# Refused patterns

Hamlet Subtractor refuses when it cannot prove a finite input, a complete
handler partition, or a direct effect dependency. It never adds a best-effort
wildcard.

Each section shows one refused form and the smallest usual fix.

## Open row

The tail of this row is unknown:

```ocaml
let source : (unit, [> `Missing ], Hamlet.never) Hamlet.t = effect
```

The PPX cannot know which other errors a generated branch must forward.

Fix: let inference produce a closed row, expose a closed named type, or state an
explicit `%hamlet.te` universe.

## Abstract, private, or hidden row

An implementation may know the variants while the current compilation unit
only sees an abstract type:

```ocaml
module Source : sig
  type error
  val value : (unit, error, Hamlet.never) Hamlet.t
end
```

Fix: export a usable closed error type, or put an explicit propagation boundary
at the abstraction boundary.

## Row chosen by a function argument

The caller chooses `error`, so this ordinary helper has no finite universe at
its definition:

```ocaml
let build error = Hamlet.Combinators.fail error
```

Fix: make the enclosing effect function a `[@hamlet.generic]` helper when its
last argument is the generic computation, or give a deliberate explicit
universe. Do not add annotations to concrete call sites merely to satisfy the
PPX.

## Effect passed as a parameter

An ordinary generic handler is compiled before any caller chooses the row:

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
