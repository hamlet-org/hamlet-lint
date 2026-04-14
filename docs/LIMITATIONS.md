# Limitations

What hamlet-lint does NOT catch today, and the reason for each gap.
All limitations below are false negatives: the walker fails in the
safe direction, so anything listed here silently escapes the lint
rather than producing a noisy false positive. For the implementation
details of what the walker *does* catch, see `ARCHITECTURE.md` §6.

---

## 1. Handlers flowing through data structures (deferred to v0.2)

The walker resolves handler arguments through a fixed set of
reference shapes (inline `function`, let-bound identifier, alias
chain, nested `let … in`, cross-module `Pdot`; see `ARCHITECTURE.md`
§6 for the complete list). Anything outside that list is a gap:

- a handler stored in a record field and read back later,
- a handler placed in a hashtable or map and looked up by key,
- a handler passed as a functor argument and invoked through the
  instantiated module,
- a handler returned from another function as a closure and applied
  at a different call site.

All four require a small intra-procedural data-flow pass (track where
each `function` value flows, join at each call site), which the v0.1
walker does not have. They are deferred to v0.2.

On such a call, the walker cannot find the `Texp_function` node, so
it cannot read the arms. The site is skipped silently, with a
`HAMLET_LINT_DEBUG=1` stderr diagnostic for investigation. You will
never get a false positive; you may get a false negative if one of
those handlers contains a stale forward.

Note that unified row types are not a substitute. The `.cmt` already
tells us `grew = out_lb \ in_lb`, but the classification into (a)
stale forward / (b) legitimate body introducer is *structural on the
arms*: it needs each pattern and each action. A data-flow pass
reconnects call sites to their `Texp_function` and hands the arms
back to the same classifier; it widens what can be analysed, it does
not replace the rule. Residual unresolvable sites (runtime-selected
handlers, opaque closure chains, arm bodies whose effect is produced
by constructs outside the syntactic introducer grammar of
`ARCHITECTURE.md` §6.2) will always remain, and will always be
skipped in the safe direction.

---

## 2. Pre-installed opam libraries are invisible

The walker reads `.cmt` files (typed AST). opam ships only `.cmi`,
`.cmti`, and `.cmxa` into `_opam/lib/<pkg>/`, never `.cmt`. Anything
installed via opam is therefore invisible to the walker. This is
shared with every typed-AST tool (merlin, mdx, ppxlib linters, and so
on).

**For library authors:** if your package uses hamlet internally and
you want a phantom-row-growth guarantee, run hamlet-lint in your own
CI before releasing. Downstream users cannot lint your code for you.

**For library users:** hamlet-lint analyses your own code and passes
silently over opam dependencies. You still catch stale forwards in
*your* code that consume a dependency's services or errors (those
live in your own `.cmt` files); you do not catch stale forwards
hidden inside the dependency itself.

See `ARCHITECTURE.md` §1.2 for the mechanism.

---

## 3. Unattributable tags on complex arm bodies

The rule classifies each tag in `grew` into (a) stale forwarding arm
(reported), (b) legitimate body introducer (silent), or (c)
unattributable (silent). Case (c) is a deliberate silence: if the
walker cannot syntactically trace where a tag came from, it says
nothing rather than guess.

One subtle consequence: in a handler like

```ocaml
catch eff ~f:(function
  | `A -> some_complex_expression_that_produces_Z
  | `Z -> failure `Z)
```

arm `` `Z `` is a textbook stale forward, but if `grew` contains `Z`
because the complex expression in arm `` `A `` happens to produce it,
the rule sees `Z` in some arm's `body_introduces` (case b) and
suppresses the report. Whether the walker resolves the complex
expression depends on the syntactic scan rules in `ARCHITECTURE.md`
§6.2 (direct `failure`, PPX constructors, inline `try_catch`, helper
chains up to depth 5). Bodies outside that grammar are treated as
contributing nothing, and the stale forward is reported as expected.

The trade-off is accepted: we prefer a false negative on exotic
bodies over a false positive on legitimate error remapping.

---

## 4. `.mli` signatures that hide the bug

The walker reads `.cmt` (implementation), never `.cmti` (signature
interface). Three cases, in decreasing order of how much value the
linter adds:

- **No `.mli`.** The compiler infers the general type with the
  phantom tag. The code type-checks, the bug is silent, the linter
  is the only thing that catches it. This is the common case.
- **`.mli` with a free row variable.** Signature coercion admits the
  contaminated row; the linter catches it, the compiler does not.
- **`.mli` with a tight concrete row.** Signature coercion itself
  rejects the implementation; a compiler error before the linter
  runs. Nothing for the linter to add, but good defence in depth.

---

## 5. OCaml version coupling

The walker links `compiler-libs` to read `.cmt` files, and
`compiler-libs` drifts across OCaml minors without semver. v0.1
supports OCaml 5.4.1 exactly, enforced by a `#error` guard in
`extract/compat.cppo.ml`. A mismatched switch fails at preprocess
time, not at typecheck time. New OCaml minors require a new cppo
branch plus a new opam package; see `RELEASING.md` §4.

---

## 6. Hamlet version coupling

The walker recognises hamlet combinators by their dotted paths
(`Combinators.provide`, `Combinators.catch`, `Layer.*`, …) and the
shape of `('a, 'e, 'r) Hamlet.t`. Additive hamlet changes (new
combinators, renames) are handled by extending the pattern list on
`main`. **Structural** hamlet changes (a fourth type parameter,
inverted argument shape, a different effect representation, altered
combinator semantics) break the walker at the destructuring level
and require code surgery, not just a new pattern. See
`ARCHITECTURE.md` §1.3 for the full catalogue of what counts as
structural. The pragmatic path is to drop support for old hamlet
versions at the walker's next major and move on.
