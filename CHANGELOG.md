# hamlet-lint changelog

Chronological walker / analyzer / compat changes on `main`. Each entry
is dated and titled by *what changed in the code*, not by a release
event. There is only one codebase (see `README.md` §2), so version
numbers like `0.1.0~5.4.1` are packaging labels, not lines of development.

Release events (the opam package for a given `(hamlet, ocaml)` pair)
live on GitHub Releases and point at the `main` commit they shipped
from. This file is where you look to understand how the walker
evolved between two commits.

Entries that affect only a specific OCaml target are tagged
`[5.4 only]`, `[5.5 only]`, etc. Unlabeled entries affect every
supported target.

## 2026-04-26 (later): hamlet uptake — `?loc` on every combinator, defect channel, PPX bare-name loc injection

Picked up five more upstream commits in `hamlet-org/hamlet` (HEAD
now at `424d7cc`): `68ed607` (#15) introduces a side-band defect
channel with a new `Hamlet.Combinators.catch_defect` combinator,
its handler initially typed `exn -> _ h`; `469a02c` is a
follow-up test fix syncing manual tags + type-error tests to the
new service-implementation shape; `f78c919` (#16) preserves the
raise-site backtrace through `Defect` re-raises and replaces the
bare `exn` carried by `Defect`/`catch_defect` with a new
`Cause.t` (raise site + backtrace + later breadcrumbs);
`a3e02a1` (#18) threads a `?loc:Source_pos.t` optional argument
through every monitored combinator (`catch`, `catch_defect`,
`provide`, `chain`, `both`, `scoped`, `map`, `map_error`, `tap`,
`sandbox`, `or_die`, plus the Layer family) and walks the
interpreter's `cont_stack` on defect to render an "effect trace"
in pretty output — leaf combinators like `return`, `failure`,
`summon`, `suspend`, `defect` take no `?loc` and are not on the
PPX whitelist either; `424d7cc` (#19) extends the loc-injection
PPX to bare-name calls under `open Hamlet[.Combinators|.Layer]`
and rewrites `let*`/`and*`/`let+` desugars when the operators
are rebound to `Hamlet.Combinators.( let* )`. The `Hamlet`
umbrella also now re-exports `Source_pos`, `Cause`, and `Exit`.

**Linter impact: none.** The walker keys off labels, not positions:
the new `?loc:Source_pos.t` is `Optional`/`Labelled "loc"`, so it
never collides with the upstream's positional `Nolabel` slot or
with the handler's `Labelled "f"`/`"h"`. `catch_defect`'s handler
takes a plain `Cause.t` (no row-typed annotation), so retroactive
widening cannot apply — it stays out of the monitored-combinator
table. `Hamlet.t` is still `(+'a, +'e, +'r) t`, so the 3-arg
structural fingerprint in `extract/classify.ml`'s
`mentions_hamlet_t` is unchanged. The fixture suites already
preprocess with `(pps ppx_hamlet)` so every whitelisted
`Hamlet.Combinators.X` call site now has a PPX-injected
`~loc:__POS__` arg in the typedtree; tests stay green because
that arg is just one more `Labelled` entry the walker is happy
to ignore. `make build` clean, `dune runtest` green on all 20
cases.

`HAMLET_VERSION` in CI remains `0.1.0` for the same reason as the
previous entry: bumping requires a hamlet opam release that
includes these commits.

## 2026-04-26: hamlet PPX uptake — `Tag.r` carries `t Hamlet.P.t`, path-qualified labels

Picked up two upstream commits in `hamlet-org/hamlet` (HEAD now at
`0fc897c`): `7839263` qualifies the service Tag's poly-variant label
with the enclosing module path using `__` as separator (top-level
declarations unchanged; nested `Outer.Inner` now emits
`` [`Outer__Inner …] ``); `0fc897c` (#14) makes the Tag's row
carry a `t Hamlet.P.t` payload — `[`Console of t Hamlet.P.t]`
rather than the previous empty `` [`Console] `` — to prevent two
services with the same short name and different service types from
silently aliasing at the row level.

**Linter impact: none.** `extract/tags.ml`'s row enumeration is
set-based on label *strings* and explicitly ignores payloads
(`Rpresent _` / `Reither _` patterns discard the payload). The
PPX-emitted handler shapes hamlet-lint matches against — pure-
propagate `failure(alias)`, `Tag.give(alias) impl`,
`Dispatch.need(alias)` — are structurally unchanged: only the
*type* of `alias` changed (now an opaque payload-carrying value),
not the call shape. Cross-CU `__Hamlet_rest_*` / `expose_*`
machinery is untouched in PPX. `make build` clean, `dune runtest`
green on all 20 cases: 7 unit/rule + 13 e2e (5 fixture suites —
widening, edge, layer, cross-CU, chained — plus 3 wire-error and
5 fs-error cases).

The opam-pinned `HAMLET_VERSION` in `.github/workflows/ci.yml`
remains `0.1.0`; bumping it requires a hamlet opam release that
includes these PPX commits. Local dev (opam pin to the standalone
hamlet checkout) follows the new HEAD automatically.

## 2026-04-24: pivot from stale forwarding arms to retroactive widening

Wholesale replacement of the detection logic. The "stale forwarding
arm" rule and its supporting machinery (8-combinator table, latent
sites, fixed-point promotion, body-introducer scanning, transitive
helper resolution) are gone. The new rule is the **retroactive
widening** check ported from `hamlet-org/hamlet` PR #9 (branch
`prototype/ppx-te-subset-probe`, dir `lint_poc/`).

**The new rule.** For every `Hamlet.Combinators.catch` /
`.provide` call, compare the handler's declared
`[%hamlet.te ...]` / `[%hamlet.ts ...]` tag universe against
upstream's effective row tags (read from `Texp_ident.val_type`
when upstream is let-bound, fallback `exp_type`). Flag tags
declared by the handler but absent from upstream. See
`docs/RULE.md` for the formal statement.

**Architecture.** Two binaries kept; wire contract simplified. The
extractor walks `.cmt` files and emits one `candidate` ND-JSON
record per recognised call (handler universe + upstream row).
The analyzer applies the rule (`declared \ upstream ≠ ∅`) and
prints findings. Schema bumped to a single `candidate` record
type; `concrete_site` / `latent_site` / `call_site` records are
gone. `schema_version = 1` (re-numbered, since the wire is
incompatible with anything older).

**Source layout.**

- `extract/` — five modules: `tags.ml`, `classify.ml`,
  `upstream.ml`, `handler.ml`, `walker.ml` + `main.ml` driver +
  `compat.cppo.ml` firewall. Total ~250 LOC, mirroring the PoC.
- `schema/` — single `candidate` record + header, `yojson`
  encoders.
- `analyzer/` — `rule.ml` (list-set difference), `report.ml`
  (multi-line pretty), `main.ml` (CLI + exit codes).
- `config/` — preserved unchanged (sexp project config, mode/
  targets/exclude).

**Recognised handler shapes (5).** Param-pat annotation,
function-cases annotation, scrutinee annotation, named identifier,
single apply-built handler. `~f` and `~h` labels both accepted.
Callee detection: full `Path.name` match plus structural
`Hamlet.t` fingerprint for `let module HC = ... in HC.catch`.

**Tests.** Old `test/cases/` (31 fixtures) trashed and replaced
with the 12 PoC fixtures (`widening_cases.ml` 5 cases,
`edge_cases.ml` 10 cases). `test/support/` vendored 1:1 from
`hamlet/test/support/` so PPX expansion stays identical.
`test_rule.ml` rewritten as pure unit tests against hand-built
schema records; `test_e2e.ml` rewritten as a table-driven
runner that pipes extract → analyzer per fixture and asserts
on the flagged line numbers.

**Documented limit.** Inline upstream (no let-binding) is a
known false negative: without a `Texp_ident` we fall back to
the already-widened `exp_type`. Workaround: bind upstream
first (`let eff = ... in catch eff ~f:...`). See
`docs/LIMITATIONS.md` §1.

**Dropped deps.** None — `yojson` stays (schema), `parsexp` /
`sexplib0` stay (config), `cmdliner` stays (CLI). One config
key (`format`) removed from the documented schema (was
reserved, never used).

`make build` clean; `dune runtest` green (5 unit + 2 e2e).

## 2026-04-15: cppo wired into extract, OCaml bound tightened to 5.4.1

`extract/compat.ml` renamed to `extract/compat.cppo.ml` and preprocessed
by `cppo` through a per-file rule in `extract/dune`
(`-V OCAML:%{ocaml_version}`). A top-of-file
`#if OCAML_VERSION < (5, 4, 1) || OCAML_VERSION >= (5, 5, 0)` / `#error`
guard asserts the exact supported version at preprocess time.
`dune-project` `(ocaml …)` bound tightened from `>= 5.4.0 < 5.5.0` to
`>= 5.4.1 < 5.4.2`; `cppo` added as a `:build` dep in `dune-project`
and as `"cppo" {>= "1.6.9" & build}` in the opam template. Future
OCaml minors add branches inside `compat.cppo.ml`; no other file in
the repo is cppo-aware.

## 2026-04-15: repo split and simplifications

hamlet-lint moved to its own repository (`hamlet-org/hamlet-lint`);
the previous `lint/` subtree in `hamlet-org/hamlet` was abandoned
without merging. Layout flattened to top-level libraries: `schema/`,
`config/`, `analyzer/`, `extract/`, `test/`.

Single semantic fix: the `Tag_provide` arm of
`combinator_kind_of_string` in `schema.ml` compared the last 13 bytes
of the input against a 12-byte literal, making that arm unreachable.
The in-process `tag_provide_stale` fixture exercised the kind
end-to-end so tests stayed green, but any ND-JSON round-trip through
the wire format silently dropped `Tag_provide`. Fixed.

Everything else is refactoring: dead code removal (`effect_loc`,
`Config.format`, `Subject_layer`), test-driver table-drivification
(`test_e2e.ml` 586 → 331 lines, zero coverage change), docs concision,
infra cleanup. Walker semantics unchanged.

## 2026-04-14: cross-module wrappers, transitive introducers, multi-level fixed-point

This entry closes the three TODOs left at the bottom of the previous
milestone's known-limits list. The contract is unchanged
(`schema_version = 1`); all changes are additive on the extractor side.
The analyzer (`rule.ml`) and the schema (`schema.ml`) are untouched.

**Cross-module wrapper resolution (P1).** Latent sites are now keyed by
the canonical dotted path of the enclosing function (e.g.
`Hamlet_lint_fixture_foo.Bar.wrap`), built from `cmt_modname` via
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
bug. On cap the binary exits with code 3 and a clear stderr message.
Cycles in `let rec` wrappers converge by the same monotone merge
without special-casing. A function promoted via two distinct upstream
exemplars produces two `latent_site` records (one per exemplar's row
shape); the analyzer iterates both joins independently, so the
"shape merge" semantics fall out naturally without any change to
`rule.ml`.

**Walker hardening.** `scan_call_sites` now skips emitting a
`call_site` when the call's argument is itself a parameter of the
enclosing function: that case is the *trigger* for fixed-point
promotion, not a concrete call. Without this guard the analyzer
would observe an unhelpful empty row lower bound (the parameter has
a free row variable) and report a false stale-forward at every
intermediate wrapper definition.

**Tests.** 12 new e2e fixtures and tests. End-to-end suite is now
33 cases (was 21):

- `wrapper_cross_module_stale`: basic cross-module join.
- `wrapper_cross_module_namespace_collision`: two modules with a
  `wrap` each, only the stale one reports.
- `errors_body_introducer_local_helper`: helper defined as nested
  `let`-in inside the enclosing function.
- `errors_body_introducer_module_helper`: helper as top-level
  `let` taking an argument.
- `errors_body_introducer_cross_module_helper`: helper resolved via
  cross-module global env.
- `errors_body_introducer_deep_chain`: four-level helper chain.
- `errors_body_introducer_runaway`: mutually-recursive helpers,
  pins termination via the visited-set short-circuit.
- `wrapper_two_level_stale`: direct two-level chain.
- `wrapper_three_level_stale`: four-level chain, multiple
  fixed-point passes.
- `wrapper_mutual_recursion`: `let rec`-defined wrappers.
- `wrapper_two_level_clean`: two-level chain whose top-level call
  is legitimate.
- `wrapper_two_level_mixed`: two distinct wrapper chains in one
  cmt, only the stale one reports.

The `errors_body_introducer_transitive` fixture's e2e snapshot was
flipped from `"body_introduces":[]` to `"body_introduces":["Bar"]`:
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

## 2026-04-14: Layer combinators, latent sites, Texp_ident handler resolution

**New recognised combinators (inline handlers):**

- `Hamlet.Layer.provide`: services row
- `Hamlet.Layer.provide_layer`: services row (peels the curried
  `svc_dep -> r_in -> r_out` handler)
- `Hamlet.Layer.provide_all`: services row (peels the `env ->` lambda)
- `Hamlet.Layer.catch`: errors row
- PPX `<Mod>.Tag.provide`: silently recognised (never stale by
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

**`Texp_ident` handler resolution.** Handlers passed by name (rather
than as a literal `function ... | ...` body) are now chased to their
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

- direct ``Combinators.failure (`Tag …)``,
- direct `Combinators.failure (<Mod>.Errors.make_<name> …)`, the PPX
  constructor, mapped to its tag by a strip-prefix-and-capitalise
  heuristic,
- direct ``Combinators.try_catch _ (fun _ -> `Tag)`` with an inline
  exn handler returning a literal variant.

Before attaching `body_introduces` to an arm, the walker subtracts the
arm's own pattern tags: a literal `` `T -> failure `T `` re-raise is the
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
- Transitive helper introducers in errors arm bodies (``let raise_bar
  () = failure `Bar`` called from an arm)
- Handlers flowing through data structures (record fields, functor
  arguments, closures returned from other functions)

## 2026-04-14: initial walker implementation

First working walker + analyzer.

**Recognised combinators (inline `function` handlers only):**

- `Combinators.provide`: services row
- `Combinators.catch`: errors row
- `Combinators.map_error`: errors row

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
  rather than any report. The schema and analyzer join logic already support
  latent records, the gap is only in the extractor emission
