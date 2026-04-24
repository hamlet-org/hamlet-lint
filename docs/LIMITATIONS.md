# Limitations

What hamlet-lint does *not* catch today, and why.

## 1. Inline upstream (false negative)

When upstream is built inline (no `let` binding) the linter has
no `Texp_ident` to read a narrow `val_type` from, falls back to
`exp_type`, and that has already been widened to match the
handler's annotation. Result: `declared = upstream`, no finding.

**Not flagged:**

```ocaml
catch (let* (module C) = Console.Tag.summon () in C.print_endline "go")
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Workaround** — bind upstream first:

```ocaml
let eff = let* (module C) = Console.Tag.summon () in C.print_endline "go" in
catch eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
(* now flagged: Database is extra *)
```

### 1.1 Chained `catch` / `provide` without intermediate `let`

Same root cause when chaining: if the inner `catch`/`provide` is
not let-bound, the outer one's upstream is a `Texp_apply` (not a
`Texp_ident`) and falls back to the already-widened `exp_type`.
This applies equally to the pipe form, since `|>` is `%revapply`
and rewrites to direct application at typedtree level.

**Outer catch silent** (Database widening on the outer is missed):

```ocaml
let eff = ... in
eff
|> catch ~f:(fun (x : [%hamlet.te Console]) -> ...)
|> catch ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Workaround** — let-bind every step, shadowing the previous name:

```ocaml
let eff = ... in
let eff = catch eff ~f:(fun (x : [%hamlet.te Console]) -> ...) in
let eff = catch eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...) in
eff
(* now every catch in the chain is flagged correctly *)
```

Reads top-to-bottom like a pipeline but each step is a `Texp_ident`
to the next, so the linter sees the narrow `val_type` instead of
the widened `exp_type`.

## 2. Handlers built by code the walker does not pattern-match

The five recognised handler shapes (param-pat annotation,
function-cases annotation, scrutinee annotation, named identifier,
single apply-built) cover the common idioms. More elaborate
constructs fall through to `Other` and emit no candidate.

**Not flagged** (handler is a `let` chain, not a `Texp_function`):

```ocaml
catch eff ~f:(let prep () = () in prep (); fun x -> ...)
```

**Workaround** — extract the handler into a named binding so it
matches shape 4 (`Texp_ident`):

```ocaml
let h x = ... in
catch eff ~f:h
```

## 3. Combinators outside the 7 monitored ones

`bind`, `pure`, `merge_all`, `try_catch`, `or_die`, `tap`,
`Layer.make`, `Layer.fresh`, `Layer.unwrap`, etc. carry no
handler that declares a row universe — the row arithmetic is
structural addition, not handler-driven. Silent by design.

```ocaml
(* not a row-handler combinator → not flagged regardless of types *)
bind eff ~f:(fun x -> ...)
try_catch ~thunk:f ~h:(fun (_ : exn) -> `Wrapped)
```

## 4. OCaml version coupling

The walker links `compiler-libs.common`, so every OCaml patch
is potentially a compatibility break. The single file
`extract/compat.cppo.ml` is the firewall:

```ocaml
#if OCAML_VERSION < (5, 4, 1) || OCAML_VERSION >= (5, 5, 0)
#error "hamlet-lint currently supports only OCaml 5.4.1"
#endif
```

Future drift adds `#if OCAML_VERSION >= (5, 5, 0)` branches there.
The analyzer is pure OCaml and unaffected.

## 5. Computed combinator references

A callee built by an expression (not a plain identifier) is not
recognised — `classify_path` matches on `Texp_ident`'s path.

**Not flagged:**

```ocaml
let combinator = if production then catch else provide in
combinator eff ~f:...
```

Idiomatic Hamlet does not write callees this way; if it became
common we would extend the classifier.

## 6. Local aliasing and partial application of the combinator

The walker only classifies an outer `Texp_apply` whose callee is a
direct `Texp_ident` resolving to a known combinator. Two related
shapes escape detection: re-binding the combinator to a local name,
and applying it in stages with the handler arriving on a second
call.

**Not flagged** (local rebinding — callee `c` is a user-bound
identifier, not a Hamlet path):

```ocaml
let c = Hamlet.Combinators.catch in
c eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Not flagged** (staged application — outer apply's callee is itself
a `Texp_apply`, not a `Texp_ident`):

```ocaml
let p = Hamlet.Combinators.catch eff in
p ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Workaround** — call the combinator in one application against a
let-bound upstream:

```ocaml
let eff = ... in
Hamlet.Combinators.catch eff
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
(* now flagged correctly *)
```

Following values across `let`-bindings would require a typed-tree
binding-tracker that is real scope creep relative to the rule;
neither shape is idiomatic Hamlet, so the linter stays narrow on
purpose.

