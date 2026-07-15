# Automatic propagation

A Hamlet computation has this type:

```ocaml
('value, 'errors, 'requirements) Hamlet.t
```

The second type parameter lists possible typed errors. The third lists services
that still need an implementation. Each named error type or service tag is an
**effect leaf**.

An automatic marker asks Hamlet Subtractor to forward every input leaf not
handled by an earlier arm:

```ocaml
[%hamlet.propagate_e.auto]  (* errors in catch *)
[%hamlet.propagate_s.auto]  (* services in provide *)
```

The PPX generates ordinary OCaml cases only after proving the complete finite
input row. If it cannot prove that no hidden leaf exists, compilation stops and
the diagnostic asks for an explicit `%hamlet.te` or `%hamlet.ts` boundary.

## Dune setup

Install the packages as shown in the [root README](../README.md#installation).
Every Dune target containing an automatic marker must use:

```lisp
(library
 (name application)
 (libraries hamlet)
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
```

The bundle already runs `ppx_hamlet`; do not list `ppx_hamlet` again in the
same target.

`pps` runs while Dune is still discovering module dependencies. On a clean
build, imported `.cmi` files may not exist at that point. A `.cmi` is the
compiled public interface of a module: it contains the exported types, values,
and compiler identities needed to understand references such as
`Storage.Errors.read_error`.

`staged_pps` runs again after Dune has built those interfaces. Hamlet
Subtractor can therefore type its temporary probe against the same imported
APIs as the final compiler. Targets without automatic markers may continue to
use ordinary `(pps ppx_hamlet)`.

The [integration guide](./integration.md#why-dune-uses-two-ppx-phases) explains
the build and Merlin lifecycle, including interface rebuilds and caching.

## Forwarding errors

Put the error marker in the final arm of an inline `catch` handler:

```ocaml
let result =
  Hamlet.Combinators.catch storage_program ~handler:(function
    | #Storage.Errors.read_error -> recover_read_error ()
    | [%hamlet.propagate_e.auto] -> .)
```

Suppose `storage_program` can fail with `read_error`, `write_error`, and
`network_error`. The first arm handles `read_error`. The PPX generates cases
that call `Hamlet.Combinators.fail` for `write_error` and `network_error`.

Only an unguarded, complete `#Path` arm removes a leaf. A guard can be false, so
the leaf must still reach the generated fallback:

```ocaml
| #Storage.Errors.read_error as error when can_retry error -> retry error
```

If a recovery arm introduces an error or requirement, that new effect remains
in the result. The PPX does not rewrite the recovery expression.

## Forwarding service requirements

Put the service marker in the final arm of an inline `provide` handler:

```ocaml
let with_logger =
  Hamlet.Combinators.provide program ~handler:(function
    | #Logger.Tag.r as witness ->
        Logger.Tag.give witness (module Logger_live)
    | [%hamlet.propagate_s.auto] -> .)
```

If `program` requires `Logger`, `Clock`, and `Database`, the `Tag.give` arm
removes `Logger`. The PPX generates `Hamlet.Dispatch.need` cases for `Clock` and
`Database`.

A direct `Hamlet.Dispatch.need witness` arm explicitly forwards that service,
so it remains in the output. Both `Tag.give` and `Dispatch.need` must receive
the witness bound by the same pattern.

Providing a service does not erase errors. Errors already present in the
computation remain present after `provide`.

## Chaining automatic markers

A linear sequence of automatic handlers is supported. The output proof from
one marker becomes the input proof for the next:

```text
source -> automatic catch -> let* -> automatic catch -> automatic provide
```

At each step the resolver combines two facts:

1. the exact output of the previous marker;
2. any new effects introduced by a supported `let*`, `chain`, `both`, or
   verified `Tag.summon` construction around that output.

A later marker may therefore handle an older leaf that survived previous
steps, or a leaf introduced after an earlier marker. There is no fixed limit on
the length of a linear chain.

The supported dependency shape is linear: each marker may depend on at most
one earlier marker. Combining two independently marked values and asking a
third marker to infer their union is refused. Add an explicit row at that merge
point.

See [Supported patterns](./supported-patterns.md#linear-marker-chains) for
complete error and requirement examples.

## Where exact input rows come from

The resolver accepts an input only when it can establish all of its leaves. The
main evidence sources are:

- a closed row or an explicit `%hamlet.te` or `%hamlet.ts` occurrence;
- an imported or independently generalized value whose open tail is local to
  a fresh use of that value;
- a verified concrete Hamlet construction, such as `return`, `fail`,
  `Tag.summon`, or supported direct composition;
- the certified output of an earlier automatic marker.

The PPX checks resolved compiler identities. A local function merely named
`fail`, `catch`, or `give` is not treated as Hamlet code.

The exact rules and small accepted examples are in
[Supported patterns](./supported-patterns.md). Matching counterexamples and
their fixes are in [Refused patterns](./refused-patterns.md).

## Explicit fallback

Use an explicit universe when the automatic proof boundary is intentionally
too narrow for the program.

For errors:

```ocaml
Hamlet.Combinators.catch source
  ~handler:(fun
    (error :
      [%hamlet.te
        Storage.Errors.read_error,
        Storage.Errors.write_error]) ->
    match error with
    | #Storage.Errors.read_error -> recover_read_error ()
    | [%hamlet.propagate_e] -> .)
```

For requirements:

```ocaml
Hamlet.Combinators.provide source
  ~handler:(fun (requirement : [%hamlet.ts Logger, Clock]) ->
    match requirement with
    | #Logger.Tag.r as witness ->
        Logger.Tag.give witness (module Logger_live)
    | [%hamlet.propagate_s] -> .)
```

This is also the correct public API for a generic helper whose callers choose
the error or requirement row.

## Cross-module generated errors

Add `[@@rest_cross_cu]` to a `%%hamlet.service` declaration when all of these
are true:

1. the service declares generated error types;
2. an automatic error marker consumes those types from another `.ml`
   compilation unit;
3. the consumer does not provide an explicit `%hamlet.te` universe.

“Another compilation unit” means another `.ml` file, including a file in the
same library. It is not limited to third-party packages.

```ocaml
[%%hamlet.service
module type Storage = sig
  type read_error = [ `Read_error of string ]
  type write_error = [ `Write_error of string ]

  val read :
    string -> (string, [> read_error | write_error ], 'requirements) Hamlet.t
end
[@@rest_cross_cu]]
```

The attribute exports a checked `Storage.Errors.Cases` catalogue. A downstream
PPX uses that catalogue to map the imported row back to complete error leaves.

| Situation | `[@@rest_cross_cu]` needed? |
| --- | --- |
| Declaration and automatic error handler are in the same `.ml` file | No |
| Automatic error handler is in another `.ml` file | Yes |
| Consumer uses an explicit `%hamlet.te` universe | No |
| Only service requirement tags cross the boundary | No |

A third-party consumer cannot add a missing catalogue to someone else's
compiled service. It must use explicit `%hamlet.te` instead. Requirement tags
already carry the needed identity, so `propagate_s.auto` does not use this
attribute.

## Continue reading

- [Supported patterns](./supported-patterns.md) contains accepted examples.
- [Refused patterns](./refused-patterns.md) explains every common refusal and
  its explicit fix.
- [Proof model](./proof-model.md) defines exact evidence and certificates.
- [Architecture](./architecture.md) follows a marker through the PPX and
  resolver.
