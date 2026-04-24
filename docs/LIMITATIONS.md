# Limitations

What hamlet-lint does *not* catch today, and why.

## 1. Inline upstream that is not itself a monitored combinator (false negative)

When upstream is built inline (no `let` binding) and isn't a call to one
of the seven monitored combinators (`Combinators.catch` / `.map_error` /
`.provide`, `Layer.catch`, `Layer.provide_to_effect` / `_to_layer` /
`_merge_to_layer`), the linter has no `Texp_ident` to read a narrow
`val_type` from and the recursive residual machinery has no inner-known
combinator to descend into. It falls back to `exp_type`, which has
already been widened to match the handler's annotation. Result:
`declared = upstream`, no finding.

**Not flagged** (upstream is `let*` desugared to `chain`, an unmonitored
combinator):

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

### 1.1 Chained `catch` / `provide` without intermediate `let` — covered

This used to be a limitation; it is now substantially solved.

When the upstream of a `catch` / `provide` / `Layer.provide_*` is itself
a call to one of the seven monitored combinators, the walker recursively
computes the inner combinator's residual row from typed-tree information
that survives covariant widening:

- **catch** with a pure-propagate handler (every arm is `failure (alias)`,
  the `[%hamlet.propagate_e]` expansion or hand-rolled equivalent) is a
  row no-op — residual = inner upstream's row.
- **provide** whose handler arms are all `Dispatch.give` (discharge) or
  `Dispatch.need` (re-emit, the `[%hamlet.propagate_s]` expansion) gets
  residual = inner upstream's row minus the union of give-tags. Mixed
  give+need handlers are the common idiom and are fully supported.
- **slot pass-through** is unconditional: an outer `catch` over an inner
  `provide` sees the inner provide as a slot-1 (errors) pass-through and
  recurses, and vice versa.

Both **pipe form** (`eff |> catch ~f:...`) and **nested form**
(`catch (catch eff ~f:...) ~f:...`) are recognised — the pipe form's
staged `Texp_apply` (partial-then-apply) is unstaged into a canonical
direct call shape before classification.

**Now flagged** (pipe form, outer catch widens past the inner's actual
emissions):

```ocaml
let eff = ... (* emits Console_error *) in
eff
|> catch ~f:(fun (x : [%hamlet.te Console]) -> ...)        (* narrow, silent *)
|> catch ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)  (* flagged *)
```

**Still NOT flagged** (catch shape that escapes the pure-propagate
detector — e.g. handler that re-throws as a *different* tag, or
`map_error` whose handler returns a tag value rather than a `failure`
call): falls back to widened `exp_type`. Workaround is the same as §1
above (bind the inner step).

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

## 6. Local aliasing and let-bound partial application

The walker classifies a callee via `Path.t` resolution. A combinator
bound to a local name loses the Hamlet-rooted path, escaping detection.
The same applies to a partial application held in a `let`-bound name
between the partial and the final argument.

**Not flagged** (local rebinding — callee `c` is a user-bound
identifier, not a Hamlet path):

```ocaml
let c = Hamlet.Combinators.catch in
c eff ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Not flagged** (let-bound partial — outer apply's callee is `p`, a
`Texp_ident` to a user-bound name; the walker has no binding-tracker
to follow `p` back to the partial `catch eff`):

```ocaml
let p = Hamlet.Combinators.catch eff in
p ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

**Workaround** — call the combinator directly, or use pipe form (which
the walker now unstages — see §1.1):

```ocaml
let eff = ... in
Hamlet.Combinators.catch eff
  ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
(* now flagged correctly *)

(* or pipe form — also flagged *)
eff |> Hamlet.Combinators.catch
       ~f:(fun (x : [%hamlet.te Console, Database]) -> ...)
```

Following values across `let`-bindings would require a typed-tree
binding-tracker that is real scope creep relative to the rule;
neither shape is idiomatic Hamlet, so the linter stays narrow on
purpose.

Note: an inline partial-then-apply chain — the shape produced by `|>`
on a partially-applied combinator, e.g. `eff |> catch ~f:H` — is **no
longer a limitation**. The walker unstages it before classification, so
any call that would be flagged in direct form is also flagged in pipe
form.
