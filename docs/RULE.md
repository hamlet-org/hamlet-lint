# The rule

What hamlet-lint analyses, what it reports, and why. Read this after
the README intro, before `ARCHITECTURE.md`.

---

## 1. The eight combinators

hamlet-lint reasons about eight handler-style combinators from
`lib/hamlet.mli`, the only places where a row is narrowed. Everything
else (`chain`, `map`, `return`, `summon`, `failure`, `or_die`, `give`,
`need`, …) is a pass-through, an introducer, or a wipe, and is out of
scope.

| # | Combinator                | Row       | Handler shape                                                                      | What "stale" means                                                              |
|---|---------------------------|-----------|-------------------------------------------------------------------------------------|---------------------------------------------------------------------------------|
| 1 | `Combinators.provide`     | services  | `'r_in -> 'r_out provide_result` via inline `function`                              | An arm's pattern tag is not in the input services lb and the body is `need r`   |
| 2 | `<Mod>.Tag.provide` (PPX) | services  | one-arm `#r as w -> give w impl` (always pure, never reportable, row-tracker only)  | Never stale by construction; present only so the row tracker drops its tag     |
| 3 | `Layer.provide`           | services  | `'svc -> 'r_in -> 'r_out provide_result`                                            | Same as row 1 after peeling the leading `svc ->` lambda                         |
| 4 | `Layer.provide_layer`     | services  | `'svc_dep -> 'r_in -> 'r_out provide_result`; subject is a **layer**, not an effect | Same as row 1; rows are read off the layer type's third parameter               |
| 5 | `Layer.provide_all`       | services  | `'env -> 'r_in -> 'r_out provide_result`                                            | Same as row 1 after peeling the leading `env ->` lambda                         |
| 6 | `Combinators.catch`       | errors    | `~f:('e -> ('a, 'f, 'r) t)`                                                         | Arm body is `failure tag'` or a helper raising a tag not in the input errors lb |
| 7 | `Combinators.map_error`   | errors    | `~f:('e -> 'f)` (pure, not an effect)                                               | Arm body is a poly variant value whose head tag is not in the input errors lb   |
| 8 | `Layer.catch`             | errors    | `~f:('e -> ('svc, 'f, 'r) layer)`                                                   | Same as row 6; row diff is on the layer's second type parameter                 |

Rows 1 and 3 through 8 are instrumented. Row 2 is recognised but
emits no site (never stale by construction). Handlers may be an inline
`function | … | …` or a `Texp_ident` referring to a `let`-bound
function; see `ARCHITECTURE.md` §6 for the full list of supported
reference shapes and the resolution depth. Unrecognised shapes are
skipped silently with a `HAMLET_LINT_DEBUG=1` stderr diagnostic.

---

## 2. Informal rule

Every handler-style call has an input effect and an output effect.
Each row of each effect has a **lower bound**: the set of polymorphic
variant tags definitely present in the row, as opposed to the ones the
row is merely open to. Call `in_lb` and `out_lb` the lower bounds of
the row of interest at the call's input and output. The *growth* of
the row at that call is

```
grew  =  out_lb  \  in_lb
```

For each tag `T` in `grew`, there must exist a *source* that
introduced it. The rule classifies that source into three cases.

### (a) Stale forwarding arm (reportable)

`T` appears in `grew` because the handler has an arm of shape
`` | `T -> need `T `` (services), `` | `T -> failure `T `` (errors),
or `` | `T -> `T `` (map_error). The arm pattern-matches `T` and its
body re-introduces `T`. `T` was never on the input side, so the arm
only keeps a phantom tag alive. **This is the bug hamlet-lint
reports.**

### (b) Legitimate body introducer (silent)

`T` appears in some arm's body `body_introduces` set, meaning the arm
legitimately produces `T` via a direct `failure` / `need` / variant
expression, a PPX `<Mod>.Errors.make_*` constructor, an inline
`try_catch`, or a transitive helper call the walker could resolve. The
tag was introduced on purpose. The rule stays silent.

Services arm bodies are `provide_result` values that cannot carry
errors, so `body_introduces` is always `[]` for them; case (b) is
errors-only.

### (c) Unattributable (silent)

`T` is in `grew`, no arm pattern-matches `T`, and no arm's body is
known to introduce `T`. The walker cannot explain where `T` came from
(it may have flowed through an inner sub-expression, or the handler
uses a shape the walker does not understand). The rule stays silent.

### How to distinguish (a) from (c)

Both can appear to "not find `T`" at a glance, but:

- **(a)** requires an arm whose **pattern is exactly `T`** and whose
  **body re-introduces `T`**. Pattern and body both about `T`.
- **(c)** is the fall-through when no such arm exists. No pattern
  matches `T`, no body introduces `T`.

The rule checks (b) first; if satisfied, (a) for that same `T` is
suppressed to avoid reporting arms on tags that legitimately flow
through the handler.

---

## 3. Wildcard suppression

A wildcard forwarding arm (`_ -> need r`, `_ -> failure e`, etc.)
makes the inferencer unify `out_lb = in_lb`, so `grew` is always
empty at that call. The extractor records
`has_wildcard_forward: true` on the handler and the analyzer
shortcuts the diff. This is explicit documentation that a genuine
forward-all handler is intentional.

---

## 4. Latent sites

When the handler lives in a wrapper function whose subject effect is
a free row-variable parameter, the walker cannot compute `grew` at
the definition, because it depends on which effect the caller passes
in. The extractor records a **latent site** keyed by the wrapper's
`Path.t` and every `Texp_apply` of that wrapper as a **call site**;
the analyzer joins the two at report time, so findings always land at
the outer call. See `ARCHITECTURE.md` §2 for the worked example and
the analyzer pseudocode.
