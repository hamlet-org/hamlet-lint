# Refused automatic-propagation patterns

Hamlet Subtractor refuses when it cannot prove the complete input row or the
meaning of a handler arm. It never forwards only the leaves it happens to see.

Each example below includes the missing fact and the normal fix.

## Abstract, private, or open rows

An abstract type hides its possible tags:

```ocaml
module Producer : sig
  type errors
  val source : (unit, errors, Hamlet.never) Hamlet.t
end
```

The consumer cannot inspect `errors`, so an automatic error marker is refused.
Expose a finite public row or add an explicit `%hamlet.te` boundary where the
universe is known.

A lower bound is not a complete row:

```ocaml
let source : (unit, [> `Missing ], Hamlet.never) Hamlet.t =
  make_source ()
```

This says `Missing` is possible; it does not exclude other errors. The value is
accepted only when independent-generalization evidence proves that its fresh
tail can be closed. Otherwise, use a closed row:

```ocaml
let source : (unit, [ `Missing ], Hamlet.never) Hamlet.t =
  make_source ()
```

Private and hidden aliases are refused for the same reason: code outside the
declaring boundary cannot prove their complete runtime representation.

## Rows chosen by callers

This builder's error row comes directly from its argument:

```ocaml
let build error = Hamlet.Combinators.fail error
```

`build `Missing` and `build `Timeout` have caller-selected effects. Closing a
fresh copy of the result row would also restrict the argument type, so the
resolver refuses.

The same problem appears when a computation itself is an argument:

```ocaml
let handle source =
  Hamlet.Combinators.catch source ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

The helper is compiled once. It cannot be re-specialized later for every
caller's `source`. Give the parameter an explicit universe and use the ordinary
marker:

```ocaml
let handle source =
  Hamlet.Combinators.catch source
    ~handler:(fun (error : [%hamlet.te Storage]) ->
      match error with
      | [%hamlet.propagate_e] -> .)
```

## Callback-controlled effects

The callback chooses the returned computation after the builder has been
compiled:

```ocaml
let build callback = callback ()
```

The callback may return any row allowed by its type. Call it outside the
automatic boundary and annotate the resulting computation explicitly.

## Mutable state

The contents of a reference can change after the resolver inspected the
definition:

```ocaml
let current = ref source
let build () = !current
```

The body does not establish one immutable origin for the effect row. Read the
reference before the handler and place an explicit row constraint on that
value.

## Object methods

The concrete method implementation is not identified by this surface call:

```ocaml
let build object_ = object_#source
```

Different objects may return different effect rows. Use a statically known
Hamlet value or an explicit boundary.

## Unverified first-class modules

An arbitrary package value has no verified connection to a generated summon:

```ocaml
module type SERVICE = sig
  val run : unit -> (unit, 'errors, 'requirements) Hamlet.t
end

let build (module Service : SERVICE) = Service.run ()
```

The resolver does not know where the module came from or whether its result row
is caller-controlled. Only a local module unpacked directly from a verified
generated `Tag.summon` is followed automatically.

## Indirect combinator aliases

The resolver recognizes the resolved canonical call, not a function value that
happens to point at it:

```ocaml
let emit = Hamlet.Combinators.fail
let source = emit `Missing
```

Call `Hamlet.Combinators.fail` directly or state the row explicitly. This small
recognized language keeps proof construction independent of arbitrary
higher-order OCaml behavior.

## Named handlers

The handler must be inline:

```ocaml
let handler = function
  | #Storage.Errors.read_error -> recover_read_error ()
  | [%hamlet.propagate_e.auto] -> .

let result = Hamlet.Combinators.catch source ~handler
```

Here the marker and owner are separated, and the same named function could be
passed to several calls. Move the function into `~handler:(function ...)`, or
use an explicit marker inside a typed helper.

## Patterns that do not prove a complete leaf

A wildcard does not identify which leaves were handled:

```ocaml
| _ -> recover ()
```

A user-written or-pattern joins tags without proving that they form one
declared leaf:

```ocaml
| (`Missing | `Timeout) -> recover ()
```

A raw payload pattern handles one runtime constructor but does not identify the
complete generated declaration:

```ocaml
| `Read_error _ -> recover ()
```

Use the generated complete paths instead:

```ocaml
| #Storage.Errors.read_error -> recover ()
| #Storage.Errors.timeout -> recover ()
```

## Unsupported producer control flow

Every possible returned computation must have a proven origin:

```ocaml
let source =
  if condition then known_source else callback ()
```

The `known_source` branch may be exact, but `callback ()` is opaque. Move the
callback result behind an explicit row boundary.

## Indirect service actions

The resolver cannot infer what these helpers do with the witness:

```ocaml
| #Logger.Tag.r as witness -> give_logger witness
| #Clock.Tag.r as witness -> forward_clock witness
```

Use the recognized operations directly:

```ocaml
| #Logger.Tag.r as witness ->
    Logger.Tag.give witness (module Logger_live)
| #Clock.Tag.r as witness -> Hamlet.Dispatch.need witness
```

## Grouped requirement aliases

One requirement leaf must identify one service tag:

```ocaml
type requirements = [ Logger.Tag.r | Clock.Tag.r ]
```

An arm against this grouped alias cannot prove which service was supplied.
Match `#Logger.Tag.r` and `#Clock.Tag.r` separately.

## Missing cross-module error catalogue

Generated error types imported from another `.ml` file need their checked
`Errors.Cases` catalogue. Without it, the downstream PPX cannot reconstruct
the complete named leaf partition:

```ocaml
Hamlet.Combinators.catch Producer.storage_program ~handler:(function
  | #Producer.Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

The service author should add `[@@rest_cross_cu]` to the declaration. If that
is impossible, the consumer must use explicit `%hamlet.te`. See
[Cross-module generated errors](./automatic-propagation.md#cross-module-generated-errors).

## Marker not last

The marker represents every case left after the user-written arms, so it must
be last:

```ocaml
match error with
| [%hamlet.propagate_e.auto] -> .
| #Storage.Errors.read_error -> recover ()
```

Move all explicit arms above the marker.

## Marker body is not a refutation

The body must be `.`:

```ocaml
| [%hamlet.propagate_e.auto] -> Hamlet.Combinators.return "fallback"
```

Automatic propagation generates the fallback body itself. Use an ordinary
pattern arm when custom behavior is intended.

## Two independent marker predecessors

A linear chain has one previous marker. This merge has two:

```ocaml
module Errors = struct
  type left_only = [ `Left_only ]
  type right_only = [ `Right_only ]
  type remaining = [ `Remaining ]
  type all = [ left_only | right_only | remaining ]
end

let left_source : (unit, Errors.all, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`Remaining : Errors.all)

let right_source : (unit, Errors.all, Hamlet.never) Hamlet.t =
  Hamlet.Combinators.fail (`Remaining : Errors.all)

let left =
  Hamlet.Combinators.catch left_source ~handler:(function
    | #Errors.left_only -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let right =
  Hamlet.Combinators.catch right_source ~handler:(function
    | #Errors.right_only -> Hamlet.Combinators.return ()
    | [%hamlet.propagate_e.auto] -> .)

let combined =
  let left = (left :> (unit, Errors.all, Hamlet.never) Hamlet.t) in
  let right = (right :> (unit, Errors.all, Hamlet.never) Hamlet.t) in
  Hamlet.Combinators.both left right
  |> Hamlet.Combinators.catch ~handler:(function
       | #Errors.remaining -> Hamlet.Combinators.return ((), ())
       | [%hamlet.propagate_e.auto] -> .)
```

The third marker would have to merge two independently narrowed certificates.
That multi-source dependency is outside the supported proof graph. Add an
explicit `%hamlet.te` boundary after `both`, then use `propagate_e`.

This does not limit ordinary linear sequences: one previous marker plus newly
proven `let*`, `chain`, or summon contributions is supported.

## Compiler modes missing from the PPX context

The standard PPX context does not report every nondefault compiler flag. For
example:

```lisp
(flags :standard -nopervasives)
```

Use an explicit boundary unless that compiler configuration is specifically
supported and tested. The resolver refuses rather than pretending it recreated
an unobservable context.

## Redundant exhausted marker

When earlier arms already handle every input leaf, no generated fallback is
needed:

```ocaml
(* source can fail only with read_error *)
| #Storage.Errors.read_error -> recover ()
| [%hamlet.propagate_e.auto] -> .
```

OCaml warning 11 remains visible because the marker arm is unreachable. Remove
the marker unless the exhausted case is intentional.

Return to the [Automatic propagation guide](./automatic-propagation.md) for
setup and explicit fallback syntax.
