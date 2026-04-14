# hamlet-lint

A semantic linter for the [Hamlet](https://github.com/hamlet-org/hamlet) effect
system. It walks the typed AST of your compiled project and hunts one very
specific bug: **phantom row growth** caused by stale forwarding arms in the
handlers of Hamlet's row-discharging combinators.

---

## 1. What hamlet-lint catches

Hamlet expresses a computation's required services and possible errors as two
open polymorphic variant rows on `('a, 'e, 'r) Hamlet.t`. Both rows grow as
effects compose and are discharged by the handler-style combinators listed in
§3. See `lib/hamlet.mli` for the full API.

The bug hamlet-lint catches is the case where a forwarding arm resurrects a
tag that the input effect never carried. Consider:

```ocaml
let prog () : (int, [> `NotFound ], 'r) Hamlet.t = failure `NotFound

let handled () =
  catch (prog ()) ~f:(function
    | `NotFound  -> success 0
    | `Timeout   -> failure `Timeout
    | `Forbidden -> failure `Forbidden)
```

`prog`'s errors row has exactly one inhabitant: `` `NotFound ``. The handler
discharges it and recovers to `success 0`, so you would expect `handled` to
have the empty errors row. Instead OCaml infers `[> `Forbidden | `Timeout ]`:
the two forwarding arms introduce `` `Timeout `` and `` `Forbidden `` into the
output row out of nowhere. Any caller of `handled` now has to prove it can
handle errors that the program provably cannot raise. That is phantom row
growth, and hamlet-lint reports both arms as stale.

The one-line rule: *every tag that appears on the output row but not on the
input row must be attributable to a real introducer on the path; if the only
thing adding it is a forwarding arm that pattern-matches it, the arm is
stale.* Section 4 states this formally.

---

## 2. Quick start

```sh
dune build
hamlet-lint-extract _build/default | hamlet-lint
```

Clean runs print `no findings` and exit 0. Findings print
`file:line:col: stale forwarding arm …` and exit 1 (exit 2 on input error,
typically a `schema_version` mismatch between the two binaries).
For install, config, flags, and CI integration see `docs/USAGE.md`.

---

## 3. The eight combinators

hamlet-lint reasons about eight handler-style combinators from
`lib/hamlet.mli` (the only places where a row is narrowed). Everything else
(`chain`, `map`, `return`, `summon`, `failure`, `or_die`, `give`, `need`, …)
is a pass-through, introducer, or wipe and is out of scope.

| # | Combinator                     | Row       | Handler shape                                                                        | What "stale" means                                                                    |
|---|--------------------------------|-----------|---------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| 1 | `Combinators.provide`          | services  | `'r_in -> 'r_out provide_result` via inline `function`                                | An arm's pattern tag is not in the input services lb and the body is `need r`         |
| 2 | `<Mod>.Tag.provide` (PPX)      | services  | one-arm `#r as w -> give w impl` (always pure, never reportable, row-tracker only)   | Never stale by construction; present in the table only so the tracker drops its tag  |
| 3 | `Layer.provide`                | services  | `'svc -> 'r_in -> 'r_out provide_result`                                              | Same as row 1 after peeling the leading `svc ->` lambda                                |
| 4 | `Layer.provide_layer`          | services  | `'svc_dep -> 'r_in -> 'r_out provide_result`; subject is a **layer**, not an effect   | Same as row 1; rows are read off the layer type's third parameter                     |
| 5 | `Layer.provide_all`            | services  | `'env -> 'r_in -> 'r_out provide_result`                                              | Same as row 1 after peeling the leading `env ->` lambda                                |
| 6 | `Combinators.catch`            | errors    | `~f:('e -> ('a, 'f, 'r) t)`                                                           | Arm body is `failure tag'` / helper raising a tag not in the input errors lb          |
| 7 | `Combinators.map_error`        | errors    | `~f:('e -> 'f)` (pure, not an effect)                                                 | Arm body is a poly variant value whose head tag is not in the input errors lb         |
| 8 | `Layer.catch`                  | errors    | `~f:('e -> ('svc, 'f, 'r) layer)`                                                     | Same as row 6; row diff is on the layer's second type parameter                       |

Rows 1 and 3 through 8 are instrumented. Row 2 is recognised but emits no site
(never stale by construction). Handlers may be a literal `function | … | …`
or a `Texp_ident` referring to a `let`-bound function; see §6 and
`docs/ARCHITECTURE.md` §6 for the full list of supported reference shapes.
Unrecognised shapes are skipped silently (`HAMLET_LINT_DEBUG=1` for stderr
diagnostics).

---

## 4. The rule

### 4.1 Informally

Every handler-style call has an input effect and an output effect. Each row
of each effect has a **lower bound**: the set of polymorphic variant tags
definitely present in the row, as opposed to the ones the row is merely open
to. Call `in_lb` and `out_lb` the lower bounds of the row of interest at the
call's input and output. The *growth* of the row at that call is

```
grew  =  out_lb  \  in_lb
```

For each tag `T ∈ grew` there must exist a *source* that introduced it:

- **(a) A stale forwarding arm.** `T` appears in `grew` because the handler
  has an arm of shape `| `T -> need `T` (services) or `| `T -> failure `T`
  (errors) or `| `T -> `T` (map_error). The arm pattern-matches `T` and its
  body re-introduces `T`; `T` was never on the input side, so the arm only
  keeps a phantom tag alive. **This is the reportable case.**

- **(b) A legitimate body introducer.** `T` appears in some arm's body's
  inferred `'e` lower bound (errors only; services arm bodies are
  `provide_result` values which cannot carry `'e`). This happens when an arm
  maps one error to another or chains into a sub-effect that raises a new
  error: the arm body computes the new tag legitimately. Stay silent.

- **(c) Unattributable.** `T` is in `grew` but the walker cannot find any arm
  explaining it: it flowed through from an inner sub-expression, or the
  handler uses a shape the walker doesn't understand. Stay silent.

### 4.2 Wildcard suppression

A wildcard forwarding arm (`_ -> need r`, `_ -> failure e`, etc.) makes the
inferencer unify `out_lb = in_lb`, so `grew` is always empty. The extractor
records `has_wildcard_forward: true` on the handler and the analyzer
shortcuts the diff. This is explicit documentation that a genuine forward-all
handler is intentional.

### 4.3 Latent sites

When the handler lives in a wrapper function whose subject effect is a
free row-variable parameter, the walker cannot compute `grew` at the
definition, because it depends on which effect the caller passes in. The
extractor records a **latent site** keyed by the wrapper's `Path.t`
and every `Texp_apply` of that wrapper as a **call site**; the
analyzer joins the two at report time, so findings always land at the
outer call. See `docs/ARCHITECTURE.md` §2 for the worked example and
the pseudocode of the rule.

---
## 5. Versioning model

hamlet-lint is published as one opam package per `(hamlet, ocaml-minor)`
pair. Package names look like `hamlet-lint.<hamlet>-<ocaml>`, e.g.
`hamlet-lint.0.1.0-5.4`. Each package pins `hamlet = <hamlet>` exactly
and targets one OCaml minor.

**One codebase.** There is only one hamlet-lint source tree: `main`.
Package version strings are labels of packaging, not lines of
divergent source history. When `hamlet-lint.0.2.0-5.4` and
`hamlet-lint.0.3.0-5.4` sit side by side on opam-repository, both were
built from the same `main` commit; the only differences are the
pinned hamlet version and the fixture compilation target.

**Two mandatory axes.** Every hamlet release (lockstep) and every
OCaml minor (compat firewall, since the extractor links
`compiler-libs`) triggers a release pass from the current `main`. New
hamlet → publish one package per supported OCaml. New OCaml → backfill
one package per past hamlet. The walker code is always whatever `main`
ships today; `main` only moves forward. The firewall lives in a single
`cppo`-preprocessed file (`extract/compat.cppo.ml`) with a top-level
`#error` guard: v0.1 pins OCaml 5.4.1 exactly.

See `docs/RELEASING.md` for the operational procedure and
`docs/ARCHITECTURE.md` for why `compiler-libs` forces the OCaml axis.

---

## 6. Coverage and limits (v0.1)

hamlet-lint instruments seven of the eight combinators from §3 (all
except `<Mod>.Tag.provide`, which is recognised but never stale by
construction). Handlers can be inline `function`, let-bound in the
same module or across modules, alias chains, or nested `let … in` RHS.
Latent wrapper sites are joined at the outer call across multi-level
chains and mutual recursion. Not yet analysed: handlers flowing
through data structures (record fields, hashmaps, functor arguments,
closures returned from functions), deferred to v0.2.

The walker always fails in the safe direction: unrecognised shapes
are skipped silently (`HAMLET_LINT_DEBUG=1` for stderr diagnostics).
False negatives only; never false positives. See `docs/ARCHITECTURE.md`
§6 for implementation details of the walker's coverage, and
`CHANGELOG.md` for walker history.

---

## 7. License and issues

hamlet-lint ships under the MIT license (`LICENSE` in the repository
root). File issues at <https://github.com/hamlet-org/hamlet-lint/issues>.
