# hamlet-lint changelog — OCaml 5.4 target

Each entry documents a release for the OCaml 5.4 compiler target. When a new
OCaml minor version becomes supported (5.5, 5.6, ...), a sibling
`CHANGES-lint-<minor>.md` file is created for that target's independent
release history.

The full opam-repository version string for an entry here is
`<feature_version>-5.4`, so the `v0.1.0` heading below is released as
`hamlet-lint.0.1.0-5.4` in opam-repository. See
`README.md#supported-ocaml-versions` for the full rationale.

## v0.1.2 (2026-04-14)

This entry closes the three v0.1.2 TODOs left at the bottom of the v0.1.1
known-limits list. The contract is unchanged (`schema_version = 1`); all
changes are additive on the extractor side. The analyzer (`rule.ml`) and
the schema (`schema.ml`) are untouched.

**Cross-module wrapper resolution (P1).** Latent sites are now keyed by
the canonical dotted path of the enclosing function — e.g.
`Hamlet_lint_fixture_foo.Bar.wrap` — built from `cmt_modname` via
`Compat.split_mangled` plus the binder name. Call sites in any cmt of
the load set canonicalise the called `Path.t` the same way before
joining. The v0.1.1 "last path component only" shortcut is gone; two
modules that each define a function called `wrap` are kept distinct.
The walker's `walk_structure` and `scan_call_sites` both take the
cmt's `modname`; the extractor binary's per-cmt phases were
restructured around four phases (globals, initial walk, fixed point,
call-site sweep) so the call-site scan runs after the load-set-wide
latent set is known.

**Transitive helper body-introducers (P2).** `scan_body_introducers`
now follows helper calls. When the scanner encounters an application
of a `Texp_ident`, it resolves the path through the same `handler_env`
mechanism that handler resolution uses (same-module locals, nested
`let`-in bindings, cross-module `Pdot` via the global env), descends
into the helper's `Texp_function` body, and unions the helper's
direct introducers into the outer arm's `body_introduces`. Recursion
is capped at depth 5 and a per-scan visited set short-circuits
cycles, so mutually recursive helpers terminate. The walker's
`walk_expr` was also extended to track a dynamic `Texp_let`-introduced
locals stack, so a helper defined inside the same enclosing function
as the `catch` is visible to the scanner when it reaches the arm.

**Multi-level wrapper chains via monotonic fixed-point (P3).** The
extractor's third phase iterates a `(canonical path → exemplar
latent_site)` table. Each pass re-scans every loaded structure for
top-level functions whose body calls a known latent wrapper with an
argument bound to one of the function's parameters; such functions
are promoted with the inner wrapper's row shape and re-enter the
table. Iteration terminates by monotonicity (no entries ever
disappear, only synthesized records are added). A hard cap of
`|fns_in_load_set| + 10` passes guards against a non-monotonic merge
bug — on cap the binary exits with code 3 and a clear stderr message.
Cycles in `let rec` wrappers converge by the same monotone merge
without special-casing. A function promoted via two distinct upstream
exemplars produces two `latent_site` records (one per exemplar's row
shape); the analyzer iterates both joins independently, so the
"shape merge" semantics fall out naturally without any change to
`rule.ml`.

**Walker hardening.** `scan_call_sites` now skips emitting a
`call_site` when the call's argument is itself a parameter of the
enclosing function — that case is the *trigger* for fixed-point
promotion, not a concrete call. Without this guard the analyzer
would observe an unhelpful empty row lower bound (the parameter has
a free row variable) and report a false stale-forward at every
intermediate wrapper definition.

**Tests.** 12 new e2e fixtures and tests. End-to-end suite is now
33 cases (was 21):

- `wrapper_cross_module_stale` — basic cross-module join.
- `wrapper_cross_module_namespace_collision` — two modules with a
  `wrap` each, only the stale one reports.
- `errors_body_introducer_local_helper` — helper defined as nested
  `let`-in inside the enclosing function.
- `errors_body_introducer_module_helper` — helper as top-level
  `let` taking an argument.
- `errors_body_introducer_cross_module_helper` — helper resolved via
  cross-module global env.
- `errors_body_introducer_deep_chain` — four-level helper chain.
- `errors_body_introducer_runaway` — mutually-recursive helpers,
  pins termination via the visited-set short-circuit.
- `wrapper_two_level_stale` — direct two-level chain.
- `wrapper_three_level_stale` — four-level chain, multiple
  fixed-point passes.
- `wrapper_mutual_recursion` — `let rec`-defined wrappers.
- `wrapper_two_level_clean` — two-level chain whose top-level call
  is legitimate.
- `wrapper_two_level_mixed` — two distinct wrapper chains in one
  cmt, only the stale one reports.

The `errors_body_introducer_transitive` fixture's e2e snapshot was
flipped from `"body_introduces":[]` to `"body_introduces":["Bar"]` —
the v0.1.1 documented-limit pin is now a v0.1.2 success.

**`compat.ml` additions:** none. P1 reuses `split_mangled` (added in
v0.1.1). P2 and P3 reuse `Compat.loc_of_location` and
`Compat.effect_type_row_lbs`.

**Known limits remaining (deferred to v0.2):**

- Handlers flowing through data structures (record fields, hashmaps,
  functor arguments, closures returned from helper functions).
  Requires a small data-flow analysis distinct from the syntactic
  walker.

`make all` is green. `make lint` (dogfood against Hamlet itself)
reports zero findings. After this entry the linter's extractor walker
is feature-complete against the `prompts/lint.md` spec for the
inline-and-named-binding handler vocabulary; the data-structure case
is the only remaining gap and is explicitly out of v0.1's scope.

## v0.1.1 (2026-04-14)

**New recognised combinators (inline handlers):**

- `Hamlet.Layer.provide` — services row
- `Hamlet.Layer.provide_layer` — services row (peels the curried
  `svc_dep -> r_in -> r_out` handler)
- `Hamlet.Layer.provide_all` — services row (peels the `env ->` lambda)
- `Hamlet.Layer.catch` — errors row
- PPX `<Mod>.Tag.provide` — silently recognised (never stale by
  construction) so the linter stops emitting a non-inline-handler
  diagnostic for every PPX-using module

**Path.t-based combinator matching.** The walker no longer matches
combinators by string-suffix on `Path.name`. A new
`extract/combinator_table.ml` module compares the `Texp_ident`'s
`Path.t` structurally against a closed table, canonicalising the
dune main-module-name wrapper (`Hamlet` vs `Hamlet__`). A pre-scan of
each structure collects in-module `let my_provide = Combinators.provide`
aliases so the user alias pattern continues to resolve.

**Latent sites for wrapper functions.** The extractor now detects calls
whose subject effect is a parameter of the enclosing named function and
emits a `latent_site` record keyed on the enclosing function's name.
A second pass over the same cmt emits `call_site` records for every
application of such a wrapper; the analyzer joins them and reports at
the outer call site. Multi-level wrapper chains (wrapper calling
wrapper) and cross-module wrapper resolution are still v0.1.2 TODOs.

**Walker diagnostics.** The "skipping non-inline handler" stderr message
is now gated behind `HAMLET_LINT_DEBUG=1`. PPX-generated calls and
unresolvable `Texp_ident` handler references are silent by default on
normal runs.

**`Texp_ident` handler resolution.** Handlers passed by name — rather
than as a literal `function ... | ...` body — are now chased to their
underlying `Texp_function`. Four reference shapes are supported:

- same-module `let`-bound handlers, keyed by `Ident.t`;
- alias chains (`let h1 = function …; let h = h1`);
- nested `let inner = function … in inner` RHS expressions (the
  resolver descends into `Texp_let` bodies);
- cross-module `Pdot` references. A two-pass extractor now pre-builds
  a global table `(canonical dotted name → Texp_function)` from every
  cmt in the load set, keyed by `split_mangled(cmt_modname) @
  [binder_name]`, then walks each cmt for sites with the global table
  in hand.

Alias chases are capped at depth 5. Handlers the resolver cannot reduce
to a `Texp_function` (library not in the load set, handler passed
through a record field, etc.) are skipped silently; the
`HAMLET_LINT_DEBUG=1` diagnostic still fires.

**Per-arm `body_introduces` (§2.3.b).** Errors-row arm bodies are now
scanned syntactically for recognised introducer shapes instead of
reading the type-inference-unified `'e` lower bound of the whole
function. The walker recognises:

- direct `Combinators.failure (`Tag …)`,
- direct `Combinators.failure (<Mod>.Errors.make_<name> …)` — the PPX
  constructor, mapped to its tag by a strip-prefix-and-capitalise
  heuristic,
- direct `Combinators.try_catch _ (fun _ -> `Tag)` with an inline exn
  handler returning a literal variant.

Before attaching `body_introduces` to an arm, the walker subtracts the
arm's own pattern tags: a literal `` `T -> failure `T`` re-raise is the
stale-forward case (§2.3.a), not a legitimate introducer, and must not
be self-silenced.

Transitive helper introducers (a helper function that itself calls
`failure`) are an explicit v0.1.2 TODO; the walker contributes nothing
to `body_introduces` for those, staying silent rather than risking
false positives.

**`compat.ml` cleanup.** The unused `effect_type_row_is_var` hook has
been removed. A new `split_mangled` helper splits dune-wrapped module
names (`Foo__Bar__Baz` → `["Foo"; "Bar"; "Baz"]`) so that cross-module
handler resolution can canonicalise `cmt_modname` against user-visible
dotted paths.

**Tests.** Eleven new fixture directories under `test/cases/`:
`aliased_provide`, `layer_provide_stale`, `layer_provide_layer_stale`,
`layer_provide_all_stale`, `layer_catch_stale`, `tag_provide_stale`,
`wrapper_stale`, `wrapper_clean`, `wrapper_no_callers`,
`let_bound_handler`, `aliased_handler`, `nested_let_handler`,
`cross_module_handler` (two modules), `unresolvable_handler`,
`errors_body_introducer_direct`, `errors_body_introducer_try_catch`,
`errors_body_introducer_ppx`, `errors_body_introducer_transitive`,
`errors_multiple_arms_distinct`. `test_e2e.ml` now drives 21 cases,
including direct ND-JSON inspection of `body_introduces` population
and a `HAMLET_LINT_DEBUG=1` stderr assertion for the unresolvable
path.

**Known limits still deferred (now v0.1.2 TODOs):**

- Multi-level wrapper chains (a wrapper calling another wrapper)
- Cross-module wrapper resolution for latent/call-site joining
- Transitive helper introducers in errors arm bodies (`let raise_bar
  () = failure \`Bar` called from an arm)
- Handlers flowing through data structures (record fields, functor
  arguments, closures returned from other functions)

## v0.1.0 (2026-04-14)

Initial release.

**Recognised combinators (inline `function` handlers only):**

- `Combinators.provide` — services row
- `Combinators.catch` — errors row
- `Combinators.map_error` — errors row

**Rule implementation:**

- `grew = output_lb \ input_lb` computed from types inferred by the compiler
  and read off `.cmt` files via `compiler-libs` 5.4 APIs
- Services row: a forwarding arm (`need r`) whose tag is in `grew` but not in
  `input_lb` is reported
- Errors row: same rule, with body-introducer suppression (if a `failure`
  inside an arm body legitimately raises a tag, that tag is not reported)
- Wildcard suppression (`_ as r -> need r` / `_ as e -> failure e`) is
  honoured: when present, `grew` is forced to `∅` by construction and the
  site is silent

**Architecture:**

- Two binaries, `hamlet-lint-extract` and `hamlet-lint`, connected via a
  streamable ND-JSON contract with an explicit `schema_version: 1` header
- `extract/compat.ml` isolates every call that touches `compiler-libs`,
  verified experimentally against real Hamlet `.cmt` files on OCaml 5.4
  before committing
- Pretty reporter with `file:line:col` locations; exit code 0 if clean, 1 if
  findings, 2 if the input ND-JSON has an unsupported schema version

**Known limits (deferred to 0.1.1):**

- Four of the eight combinators from the spec are not yet recognised:
  `Layer.provide`, `Layer.provide_layer`, `Layer.provide_all`, `Layer.catch`
- PPX-generated `Foo.Tag.provide` handlers are not recognised
- Handlers passed as `Texp_ident` (let-bound or imported from another module)
  are skipped with a stderr diagnostic
- Latent sites (wrapper functions whose argument is a free row variable) are
  walked as if concrete with `in_lb = ∅`, producing silent false negatives
  rather than any report — the schema and analyzer join logic already support
  latent records, the gap is only in the extractor emission
