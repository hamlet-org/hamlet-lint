# Automatic propagation

A Hamlet computation has three type parameters:

```ocaml
('value, 'errors, 'requirements) Hamlet.t
```

`'errors` lists failures that may be raised. `'requirements` lists services
that still need an implementation.

Automatic propagation lets a handler process some entries and forward the
rest without writing the complete input row by hand:

```ocaml
[%hamlet.propagate_e.auto]  (* errors *)
[%hamlet.propagate_s.auto]  (* services *)
```

The PPX accepts a marker only when it can prove the complete finite input row.
It subtracts the entries handled by preceding arms and generates ordinary OCaml
cases for the remainder. If the row is not provably complete, it asks for an
explicit `%hamlet.te` or `%hamlet.ts` boundary.

## Project setup

Install the packages as shown in the [root README](../README.md#installation).
Then use the staged bundle in every target containing an automatic marker:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The same field works in `executable` and `test` stanzas. The bundle includes
`ppx_hamlet`, so do not add `ppx_hamlet` again in that target.

Targets that only use Hamlet declarations or explicit propagation may keep:

```lisp
(preprocess
 (pps ppx_hamlet))
```

### Why `staged_pps` is required

`pps` and `staged_pps` run a PPX at different points in a Dune build:

| Dune field | When it runs | Suitable for |
| --- | --- | --- |
| `pps` | Early, while Dune is still discovering dependencies | Syntax rewriting that does not need imported type information |
| `staged_pps` | Again when the compiler runs, after dependencies are built | Rewriting that needs the compiled interfaces of imported modules |

The subtractor needs imported type information. For example, when a handler
mentions `Storage.Errors.read_error`, the PPX must know which declaration that
path resolves to, every error in the relevant generated catalogue, and the
actual type of the input computation.

OCaml stores the public typed API of a compiled module in a `.cmi` file. This
is its **dependency interface**. `Storage.cmi`, for example, contains the
exported types and values of `Storage` together with the identities used by the
type checker. It does not contain the module implementation.

During ordinary `pps`, those `.cmi` files may not exist yet on a clean build.
During `staged_pps`, Dune has already built them, so the resolver can type its
temporary probe against the same imports as the final compiler. The ordinary
`pps` form is rejected for automatic markers instead of producing a weaker
result.

Suppose you are editing `A.ml` and it imports `B`. Merlin sends the PPX the
current in-memory contents of `A.ml`, including unsaved changes. The PPX does
not receive the source of `B`; it receives `B.cmi`, the interface produced the
last time Dune compiled `B`. If you change an exported type or value in `B`,
Dune must rebuild `B.cmi` before analysis of `A.ml` can see that change.

Do not enable Merlin's optional external PPX result cache. Consider a consumer
whose source has not changed while `Storage.cmi` gains a new error. The cache
key does not include that `.cmi`, so Merlin could reuse forwarding code proved
against the old error set. With the cache disabled, the staged PPX runs again
and reads the new interface. Dune's normal Merlin configuration leaves this
cache disabled.

## Errors

Place `propagate_e.auto` in the final arm of an inline `catch` handler:

```ocaml
let recovered =
  Hamlet.Combinators.catch storage_program
    ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error as error -> recover error
      | [%hamlet.propagate_e.auto] -> .)
```

If `storage_program` can fail with `read_error`, `write_error`, and
`network_error`, the first arm removes `read_error`. The generated arm forwards
`write_error` and `network_error` with `Hamlet.Combinators.fail`.

Errors and requirements introduced by recovery code remain in the result:

```ocaml
| #Storage.Errors.read_error ->
    Hamlet.Combinators.fail `Recovery_failed
```

Here `Recovery_failed` is added to the residual error row. The recovery branch
itself is not rewritten.

An error leaf is removed only by an unguarded, complete `#Path` pattern:

```ocaml
| #Storage.Errors.read_error -> recover ()
| #Storage.Errors.read_error as error -> recover error
```

A guarded arm does not remove the leaf because control can continue to the
automatic arm when the guard is false:

```ocaml
| #Storage.Errors.read_error as error when retryable error -> recover error
```

## Service requirements

Place `propagate_s.auto` in the final arm of an inline `provide` handler:

```ocaml
let with_logger =
  Hamlet.Combinators.provide program
    ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
```

If `program` requires `Logger`, `Clock`, and `Database`, the `Tag.give` arm
removes `Logger`. The generated arm forwards `Clock` and `Database` with
`Hamlet.Dispatch.need`.

An arm that directly calls `Dispatch.need witness` explicitly forwards its
service, so that service remains in the output row. Both `Tag.give` and
`Dispatch.need` must use the witness bound by the same pattern. A guard prevents
subtraction for the same reason as in an error handler.

`provide` does not subtract errors. The source error row and any errors raised
by the supplied implementation remain part of the result.

## What the PPX can prove

The following examples use values such as `source`, `recover`, and `logger`
defined elsewhere. Each example focuses only on the shape being discussed.

### Supported handler shapes

A direct call with an inline handler is supported:

```ocaml
Hamlet.Combinators.catch source ~handler:(fun error ->
  match error with
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

Pipeline form is equivalent:

```ocaml
source
|> Hamlet.Combinators.catch ~handler:(function
     | #Storage.Errors.read_error -> recover ()
     | [%hamlet.propagate_e.auto] -> .)
```

A complete error arm uses a generated `#Path`, optionally with an alias:

```ocaml
| #Storage.Errors.read_error -> recover ()
| #Storage.Errors.write_error as error -> inspect error
```

A complete service arm binds its witness and uses it directly:

```ocaml
| #Logger.Tag.r as witness -> Logger.Tag.give witness logger
```

The automatic marker is always the final arm and its body is `.`:

```ocaml
| [%hamlet.propagate_e.auto] -> .
```

### Supported input sources

A closed row is exact by construction:

```ocaml
let source : (_, [ `Missing | `Timeout ], Hamlet.never) Hamlet.t =
  make_source ()
```

An explicit occurrence is also exact:

```ocaml
(source : (_, [%hamlet.te Storage], _) Hamlet.t)
```

An imported or independently generalized value can be exact even when its
printed type uses `[> ... ]`:

```ocaml
(* producer.mli *)
val source : ('a, [> Storage.Errors.read_error ], 'requirements) Hamlet.t

(* consumer.ml *)
Hamlet.Combinators.catch Producer.source ~handler:(function
  | [%hamlet.propagate_e.auto] -> .)
```

The resolver creates a fresh copy of the exported type and checks that its row
tail can be closed without changing any type variable outside that copy. If it
cannot, the value is refused.

Recognized concrete Hamlet construction is exact:

```ocaml
let source =
  let open Hamlet.Combinators in
  let* () = fail `Missing in
  fail `Timeout
```

The proven output of one marker can feed another:

```ocaml
let without_read =
  Hamlet.Combinators.catch source ~handler:(function
    | #Storage.Errors.read_error -> recover ()
    | [%hamlet.propagate_e.auto] -> .)

let without_write =
  Hamlet.Combinators.catch without_read ~handler:(function
    | #Storage.Errors.write_error -> recover ()
    | [%hamlet.propagate_e.auto] -> .)
```

The PPX verifies resolved declaration identities, not printed names. This
lookalike is not accepted as Hamlet's `fail`:

```ocaml
let fail error = Error error
let source = fail `Missing
```

### Local builders and first-class service modules

Concrete local builders do not need an explicit row annotation when the
resolver can follow their construction:

```ocaml
let build_requirement_source () =
  let open Hamlet.Combinators in
  let* (module Logger) = Logger.Tag.summon in
  let* () = Logger.log "ciao" in
  let* (module Clock) = Clock.Tag.summon in
  let* now = Clock.now () in
  return (Printf.sprintf "ready at %d" now)
```

`ppx_hamlet` adds the package type to each `(module Service)` pattern. After it
lowers `Service.Tag.summon` to Hamlet's primitive summon call, the resolver
checks that the key and tag belong to that generated service. It then follows
Hamlet computations called through the verified local module. In the example,
providing `Logger` leaves `Clock` in the requirement row.

This does not make arbitrary first-class modules exact. The module must come
directly from a verified generated summon and retain the package type inserted
by `ppx_hamlet`.

A directly applied local builder is supported when it is independently
generalized and its result row does not depend on its arguments. A
`unit -> Hamlet.t` builder is the common case:

```ocaml
let build () = Hamlet.Combinators.fail `Missing

let handled =
  Hamlet.Combinators.catch (build ()) ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

The following builders are not exact because the effect row comes from a value
outside the builder's independently typed body.

From an argument:

```ocaml
let build error = Hamlet.Combinators.fail error
```

From a callback:

```ocaml
let build callback = callback ()
```

From mutable state:

```ocaml
let current = ref source
let build () = !current
```

From an object method:

```ocaml
let build object_ = object_#source
```

From an unverified first-class module:

```ocaml
let build (module Service : SERVICE) = Service.run ()
```

An indirect alias of a combinator is also outside the recognized construction
language:

```ocaml
let emit = Hamlet.Combinators.fail
let source = emit `Missing
```

A marker in a generic helper is resolved once, when the helper itself is
compiled. It is not specialized for each later caller:

```ocaml
let handle source =
  Hamlet.Combinators.catch source ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

Here the input row is controlled by the `source` parameter, so the helper needs
an explicit `%hamlet.te` boundary.

## Common refusals

The PPX refuses rather than guessing in each case below.

**Abstract or hidden row:** the consumer cannot see the complete definition.

```ocaml
module Producer : sig
  type errors
  val source : (unit, errors, Hamlet.never) Hamlet.t
end
```

Private rows are refused for the same reason. A genuinely open row is also not
a complete universe:

```ocaml
type errors = private [ `Missing ]

let source : (_, [> `Missing ], _) Hamlet.t = make_source ()
```

This annotation alone is not proof that `Missing` is the only possible error.

**Parameter-controlled or callback-controlled row:** the caller chooses the
effects after the helper has been compiled.

```ocaml
let handle (source : (_, 'errors, _) Hamlet.t) =
  Hamlet.Combinators.catch source ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

```ocaml
let handle make_source =
  Hamlet.Combinators.catch (make_source ()) ~handler:(function
    | [%hamlet.propagate_e.auto] -> .)
```

**Named handler:** the supported relationship between owner, input, and arms is
no longer visible in one expression.

```ocaml
let handler = function
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .

let result = Hamlet.Combinators.catch source ~handler
```

**Unsupported patterns:** only generated complete `#Path` leaves can be
subtracted. These examples are refused:

```ocaml
| _ -> recover ()                              (* wildcard *)
| (`Missing | `Timeout) -> recover ()          (* user or-pattern *)
| `Read_error _ -> recover ()                  (* raw payload pattern *)
```

Unsupported producer control flow is also refused when not every possible
result can be traced:

```ocaml
let source = if condition then known_source else callback ()
```

**Indirect service action:** the resolver cannot prove what the helper does
with the witness.

```ocaml
| #Logger.Tag.r as witness -> give_logger witness
| #Clock.Tag.r as witness -> forward_service witness
```

Use the direct call instead:

```ocaml
| #Logger.Tag.r as witness -> Logger.Tag.give witness logger
```

**Grouped requirement alias:** one arm cannot prove which service was supplied.

```ocaml
type requirements = [ Logger.Tag.r | Clock.Tag.r ]
```

Handle `#Logger.Tag.r` and `#Clock.Tag.r` as separate leaves.

**Imported error universe without `Errors.Cases`:** the downstream module can
see the error type but cannot reconstruct its complete generated leaf
partition. Add `[@@rest_cross_cu]` to the service declaration or use an
explicit `%hamlet.te` boundary. The next section shows both forms.

**Marker before another arm:** the marker must be last.

```ocaml
match error with
| [%hamlet.propagate_e.auto] -> .
| #Storage.Errors.read_error -> recover ()
```

**Compiler mode missing from the PPX context:** for example, this target must
use an explicit boundary because the resolver cannot observe `-nopervasives`:

```lisp
(flags :standard -nopervasives)
```

When every input leaf has already been handled, the marker is redundant:

```ocaml
(* source can fail only with read_error *)
| #Storage.Errors.read_error -> recover ()
| [%hamlet.propagate_e.auto] -> .  (* warning 11 *)
```

OCaml warning 11 remains visible. Remove the marker unless the exhausted case
is intentional.

## Explicit fallback

For errors, write the complete input universe with `%hamlet.te` and use the
ordinary propagation marker:

```ocaml
Hamlet.Combinators.catch source
  ~handler:(fun
    (error :
      [%hamlet.te
        Storage.Errors.read_error, Storage.Errors.write_error]) ->
    match error with
    | #Storage.Errors.read_error -> recover ()
    | [%hamlet.propagate_e] -> .)
```

`[%hamlet.te Storage]` names the complete generated error universe for a
service.

For requirements, use `%hamlet.ts`:

```ocaml
Hamlet.Combinators.provide source
  ~handler:(fun (requirement : [%hamlet.ts Logger, Clock]) ->
    match requirement with
    | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
    | [%hamlet.propagate_s] -> .)
```

An explicit boundary is also the right API for a public polymorphic function
whose callers determine the row.

## Cross-module error catalogues

`[@@rest_cross_cu]` is required when all three conditions are true:

1. a `%%hamlet.service` declaration defines generated error leaves;
2. an automatic error marker consumes those errors from another compilation
   unit, library, or package;
3. the consumer does not provide an explicit `%hamlet.te` universe.

“Another compilation unit” means another `.ml` file, even inside the same
project. It is not limited to third-party packages.

The rule is:

| Situation | Is `[@@rest_cross_cu]` required? |
| --- | --- |
| Service declaration and automatic error handler are in the same `.ml` file | No |
| Automatic error handler imports the generated errors from another `.ml` file | Yes |
| Automatic error handler consumes generated service errors from another library or package | Yes |
| Consumer uses an explicit `%hamlet.te` universe | No |
| Only generated requirement tags cross the boundary | No |

The service author enables cross-module automatic error propagation on the
declaration:

```ocaml
[%%hamlet.service
module type Storage = sig
  type read_error = [ `Read_error of string ]
  type write_error = [ `Write_error of string ]

  val read :
    string -> (string, [> read_error | write_error ], 'r) Hamlet.t
end
[@@rest_cross_cu]]
```

This generates a checked `Storage.Errors.Cases` catalogue in the compiled
interface. A downstream PPX uses it to prove that it knows every generated
error leaf and to generate forwarding code in linear time.

Without the attribute, this downstream automatic handler is refused:

```ocaml
(* another .ml file *)
Hamlet.Combinators.catch Storage_program.source ~handler:(function
  | #Storage.Errors.read_error -> recover ()
  | [%hamlet.propagate_e.auto] -> .)
```

If `Storage` is owned by a third party and its declaration does not use
`[@@rest_cross_cu]`, the consumer cannot add the missing catalogue. It must use
the explicit form:

```ocaml
Hamlet.Combinators.catch Storage_program.source
  ~handler:(fun (error : [%hamlet.te Storage]) ->
    match error with
    | #Storage.Errors.read_error -> recover ()
    | [%hamlet.propagate_e] -> .)
```

Requirement tags already carry enough identity, so `propagate_s.auto` does not
need `[@@rest_cross_cu]`.

The producer can use ordinary `pps ppx_hamlet`. Only the target containing the
automatic marker requires `staged_pps hamlet-subtractor.ppx`.

## Tests and internals

Run the public acceptance gate with:

```sh
dune runtest test/automatic_propagation
```

See the [acceptance-test README](../test/automatic_propagation/README.md) for
focused commands and fixture rules. For implementation details, continue with
the [architecture guide](./architecture.md).
