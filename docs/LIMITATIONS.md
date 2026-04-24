# Limitations

What hamlet-lint does *not* catch today, and why.

## 1. Upstream row widened at let-binding (false negative)

Two situations produce the same root cause: by the time the linter
reads upstream's row, OCaml has already widened it to match the
handler's annotation, so `declared = upstream` and no finding fires.

### 1.1 Inline upstream

Calls where the upstream effect is built inline rather than
let-bound:

```ocaml
catch
  (let* (module C) = Console.Tag.summon () in C.print_endline "go")
  ~f:(fun (x : [%hamlet.te Console_error, Database_error]) ->
      match x with [%hamlet.propagate_e] -> .)
```

Because there is no `Texp_ident` for upstream, the linter falls
back to `exp_type`. By the time the typechecker stored
`exp_type` the covariant subtyping has widened the row to match
the handler's annotation — the linter sees `declared = upstream`
and emits no finding. See `docs/RULE.md` §5.

**Workaround.** Bind upstream first:

```ocaml
let eff = let* (module C) = ... in C.print_endline "go" in
catch eff ~f:...
```

### 1.2 `Layer.t` upstream built via `Layer.make`

`Layer.provide_to_layer ~s:dep ~h:(fun impl x -> ...) target` and
`Layer.provide_merge_to_layer ~s:env ~h:(...) target`: when `target`
was built with `Layer.make key build`, OCaml's value restriction
gives it weak row variables (`'_r`). The handler's annotation
unifies `target`'s `'_r` to its declared universe BEFORE the
linter reads `Texp_ident.val_type`, so widening becomes invisible.

The classifier still recognises both combinators (the candidate is
emitted, just always with `declared = upstream`). The two GOOD
fixtures `lpl_provide_to_layer_narrow` and
`lpm_provide_merge_to_layer_narrow` in
`test/cases/layer_cases.ml` lock in that no false positive fires.

**No clean workaround**: pinning `target`'s row via an explicit
type annotation would make OCaml itself reject the widening at
compile time, defeating the linter's purpose. In practice this
limit only matters for layers built and then immediately consumed
in the same scope; a layer constructed in one module and consumed
in another typically has its row pinned by the consumer's
signature, in which case `Combinators.provide` (with a let*-chain
upstream) catches the widening.

## 2. Handlers built by code the walker does not pattern-match

The five recognised handler shapes (param-pat annotation,
function-cases annotation, scrutinee annotation, named
identifier, single apply-built) cover the PoC fixtures and the
common idioms. Handlers built by more elaborate constructs (a
chain of `let ... in ...` whose body is a `Texp_function`, a
ppx-generated wrapper around a function-cases value, a handler
returned from a partial application of a partial application,
etc.) currently fall through to `Other` and emit no candidate.

A future extension would walk through one or two layers of
expression structure before giving up. Tracked, not yet a
priority.

## 3. Combinators outside catch / provide

Hamlet has other combinators (`bind`, `pure`, `merge_all`, etc.)
but none of them carry handlers that can declare a wider
universe than upstream — the row arithmetic is structural
addition, not handler-driven discharge. The linter is silent on
those by design.

## 4. Cross-CU upstream and the PPX `[@@rest_cross_cu]` shape

When upstream lives in a different compilation unit and is
re-exported through hamlet's `[@@rest_cross_cu]` machinery, the
linter still walks the call site's `.cmt`. The val_type the
walker reads is the post-typechecker materialisation: cross-CU
should work transparently, but exotic cases involving the
synthesised `__Hamlet_rest_*` aliases have not been
exhaustively tested. File an issue with a minimal reproducer if
you hit one.

## 5. OCaml version coupling

The walker links `compiler-libs.common`, which means every
patch of the OCaml compiler is potentially a compatibility
break. The single file `extract/compat.cppo.ml` is the firewall
(currently a `#error` guard pinning 5.4.1; future drift will
add `#if OCAML_VERSION >= (5, 5, 0)` branches there). The
analyzer does not depend on `compiler-libs` and is unaffected.

## 6. Computed combinator references

`(if cond then catch else provide) eff ~f:...` and similar
syntactic obfuscations of the callee are not recognised. The
walker's `classify_path` looks at a `Texp_ident`'s path; an
`Texp_ifthenelse` in callee position is skipped. Idiomatic
hamlet code does not write callees this way; if it became
common we would extend the classifier.
