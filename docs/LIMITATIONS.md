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

---

## Verified to work (no longer limits)

The following were caveats in earlier drafts but are now covered
end-to-end:

- **Cross-CU services with `[@@rest_cross_cu]`**. The linter walks
  the consumer's `.cmt` and reads the upstream's `val_type` even
  when the row was assembled via the producer's synthesised
  `__Hamlet_rest_*` aliases. Exercised by
  `test/cases/cross_cu_cases.ml` (xc1–xc4).
- **`Layer.t` upstream built via `Layer.make`**. Hamlet `d62acb7`
  made `Layer.t` covariant in `'e` / `'r`; the typechecker now
  keeps the layer's row narrow at `val_type` while widening at
  the call site. Exercised by `lc2`, `lpe2`, `lpl2`, `lpm2` in
  `test/cases/layer_cases.ml`.
