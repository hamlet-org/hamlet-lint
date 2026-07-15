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

The handler must have this shape:

- a direct `Hamlet.Combinators.catch` or `provide` call, including pipeline
  form;
- an inline `fun` or `function` handler;
- complete `#Path` error arms or direct `#Service.Tag.r as witness` service
  arms;
- the automatic marker as the final arm, with `.` as its body;
- a finite input row obtained from one of the exact sources below.

An input row is exact when it comes from one of these sources:

- a closed row or an explicit `%hamlet.te`/`%hamlet.ts` occurrence;
- an imported or independently generalized value whose fresh row can be closed
  to the visible leaves without constraining its environment;
- a recognized concrete Hamlet expression such as `success`, `return`,
  `fail`, generated `Tag.summon`, or supported direct composition;
- the proven output of an earlier automatic marker.

The PPX verifies resolved declaration identities, not printed names. A local
function named `fail`, `catch`, or `give` is not treated as Hamlet code.

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
`unit -> Hamlet.t` builder is the common case. A helper whose error row is
derived from an argument, a callback, mutable state, an object, or an unknown
first-class module needs an explicit boundary.

The same rule excludes indirect combinator aliases and unsupported
higher-order composition. A marker inside a generic helper is resolved when
that helper is compiled; it is not specialized again for each caller.

## Common refusals

The PPX refuses rather than guesses when it sees:

- an abstract, private, hidden, or genuinely open row;
- a row controlled by a function parameter or higher-order callback;
- a named or otherwise indirect handler;
- wildcard, user-written or-pattern, partial-payload, or unsupported
  control-flow arms;
- an indirect `Tag.give` or `Dispatch.need` helper call;
- a grouped requirement alias containing more than one service tag;
- an external error universe without the required catalogue;
- a marker that is not the last arm;
- a nondefault compiler mode that the standard PPX context cannot report.

When every input leaf has already been handled, the marker is redundant and
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

When another compilation unit will automatically propagate a generated
service's errors, declare the service with `[@@rest_cross_cu]`:

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

This generates a checked `Errors.Cases` catalogue. A downstream PPX can then
map the input row back to complete named leaves and generate forwarding code in
linear time. Requirement tags already carry enough identity and need no extra
option.

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
