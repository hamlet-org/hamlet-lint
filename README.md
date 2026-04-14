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
`file:line:col: stale forwarding arm …` and exit 1 (exit 2 on input error —
typically a `schema_version` mismatch between the two binaries).
For install, config, flags, and CI integration see `docs/USAGE.md`.

---

## 3. The eight combinators

hamlet-lint reasons about eight handler-style combinators from
`lib/hamlet.mli` — the only places where a row is narrowed. Everything else
(`chain`, `map`, `return`, `summon`, `failure`, `or_die`, `give`, `need`, …)
is a pass-through, introducer, or wipe and is out of scope.

| # | Combinator                     | Row       | Handler shape                                                                        | What "stale" means                                                                    |
|---|--------------------------------|-----------|---------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| 1 | `Combinators.provide`          | services  | `'r_in -> 'r_out provide_result` via inline `function`                                | An arm's pattern tag is not in the input services lb and the body is `need r`         |
| 2 | `<Mod>.Tag.provide` (PPX)      | services  | one-arm `#r as w -> give w impl` — always pure, never reportable, row-tracker only   | Never stale by construction; present in the table only so the tracker drops its tag  |
| 3 | `Layer.provide`                | services  | `'svc -> 'r_in -> 'r_out provide_result`                                              | Same as row 1 after peeling the leading `svc ->` lambda                                |
| 4 | `Layer.provide_layer`          | services  | `'svc_dep -> 'r_in -> 'r_out provide_result`; subject is a **layer**, not an effect   | Same as row 1; rows are read off the layer type's third parameter                     |
| 5 | `Layer.provide_all`            | services  | `'env -> 'r_in -> 'r_out provide_result`                                              | Same as row 1 after peeling the leading `env ->` lambda                                |
| 6 | `Combinators.catch`            | errors    | `~f:('e -> ('a, 'f, 'r) t)`                                                           | Arm body is `failure tag'` / helper raising a tag not in the input errors lb          |
| 7 | `Combinators.map_error`        | errors    | `~f:('e -> 'f)` — pure, not an effect                                                 | Arm body is a poly variant value whose head tag is not in the input errors lb         |
| 8 | `Layer.catch`                  | errors    | `~f:('e -> ('svc, 'f, 'r) layer)`                                                     | Same as row 6; row diff is on the layer's second type parameter                       |

Rows 1 and 3–8 are instrumented. Row 2 is recognised but emits no site
(never stale by construction). Handlers may be a literal `function | … | …`
or a `Texp_ident` referring to a `let`-bound function; the walker resolves
the four reference shapes listed in §12 up to depth 5, silently skipping
anything else (`HAMLET_LINT_DEBUG=1` for stderr diagnostics).

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
  explaining it — it flowed through from an inner sub-expression, or the
  handler uses a shape the walker doesn't understand. Stay silent.

### 4.2 Wildcard suppression

A wildcard forwarding arm (`_ -> need r`, `_ -> failure e`, etc.) makes the
inferencer unify `out_lb = in_lb`, so `grew` is always empty. The extractor
records `has_wildcard_forward: true` on the handler and the analyzer
shortcuts the diff — explicit documentation that a genuine forward-all
handler is intentional.

### 4.3 Concrete vs latent sites

A call like

```ocaml
catch prog ~f:(function ...)
```

is **concrete** when the walker can read `in_lb` directly off `prog`'s
inferred type. But when the programmer writes a wrapper

```ocaml
let wrap eff = catch eff ~f:(function ...)
```

the handler is syntactically present at `wrap`'s definition but the input
effect is a free row variable parameter. The walker cannot compute `grew` at
the definition site — it depends on which `eff` the caller passes in. So the
extractor records a **latent site** keyed by the enclosing function's
`Path.t`, and every `Texp_apply` of that function as a **call site**. The
analyzer joins latent arms against each call site's argument row lb; the
finding always lands at the outer call, never at the handler's definition
(whether a mixed discharge/forward handler is buggy depends on which `eff`
the caller passes, and different calls can differ).

Wrapper chains iterate naturally until they bottom out at a concrete call.
Latent sites whose function has zero calls in the cmt set are silently
dropped.

### 4.4 The analyzer in pseudocode

```
def check(row, in_lb, loc):
  if row is None or row.handler.has_wildcard_forward: return
  for tag in set(row.out_lower_bound) - set(in_lb):
    if any(tag in arm.body_introduces for arm in row.handler.arms):
      continue                      # (b) legitimate body introducer
    for arm in row.handler.arms:    # (a) stale forward
      if arm.tag == tag and arm.action == Forward:
        report(loc, arm, row)
        break
    # (c) otherwise silent

for site in concrete_sites:
  check(site.services, site.services.in_lb, site.loc)
  check(site.errors,   site.errors.in_lb,   site.loc)

for lat in latent_sites:
  for call in calls where call.function_path == lat.latent_in_function:
    check(lat.services, call.arg_services_lb, call.loc)
    check(lat.errors,   call.arg_errors_lb,   call.loc)
```

(Implementation in `analyzer/rule.ml`.)

---

## 5. Why `.cmt` files

Row lower bounds exist only after type inference, so the linter cannot be a
`ppxlib` PPX (PPX runs before inference). `.cmt` files are the typed AST the
compiler emits under `_build/default/**/*.cmt`; `compiler-libs` provides
`Cmt_format.read_cmt` to parse them back. The tool is therefore version-locked
against `compiler-libs` (`Typedtree`, `Types`, and friends drift across OCaml
minors without semver); §9 covers the version-support policy.

### 5.1 `.cmt` vs `.cmti`

The extractor walks `.cmt` only, never `.cmti`:
`Filename.check_suffix f ".cmt" && not (Filename.check_suffix f ".cmti")`
in `extract/main.ml`. Consequence: **the linter sees through signature
abstraction** — an opaque `.mli` that hides or narrows a row does not hide
the implementation's raw `provide`/`catch`/`map_error` calls from
hamlet-lint.

Three `.mli` cases, in decreasing order of how much value the linter adds:

- **No `.mli`.** The compiler infers the general type with the phantom tag.
  The code type-checks, the bug is silent, the linter is the only thing
  that catches it — the common case.
- **`.mli` with a free row variable.** Signature coercion admits the
  contaminated row; the linter catches it, the compiler does not.
- **`.mli` with a tight concrete row.** Signature coercion itself rejects
  the impl — compiler error before the linter runs. Good defence-in-depth,
  nothing for the linter to add.

### 5.2 Pre-installed libraries are invisible

opam ships `.cmi`/`.cmti`/`.cmxa` into `_opam/lib/<pkg>/` but not `.cmt`,
so anything installed from opam is invisible to the walker. This is shared
with every typed-AST tool (merlin, mdx, ppxlib linters, …).

Consequence for **library authors**: if your package uses Hamlet internally
and you want a phantom-row-growth guarantee, run hamlet-lint in your own CI
before releasing. Downstream users cannot lint it for you.

For **library users**: the linter analyses your own code and passes silently
over opam dependencies. You still catch stale forwards in your code that use
a dependency's services or errors (those live in your own `.cmt`s); you do
not catch stale forwards inside the dependency itself.

---

## 6. Concrete vs latent: a worked example

```ocaml
(* Wrapper function: handler is here, input effect is a free parameter *)
let give_console eff =
  Combinators.provide
    (function
      | #Console.Tag.r as w -> Console.Tag.give w "stdout"
      | #Logger.Tag.r  as r -> Combinators.need r)
    eff

(* Call site A: eff has services lb = {Console} *)
let a () = give_console (Combinators.summon Console.Tag.key `Console)

(* Call site B: eff has services lb = {Console, Logger} *)
let b () =
  give_console
    (let* c = Combinators.summon Console.Tag.key `Console in
     let* _ = Combinators.summon Logger.Tag.key  `Logger  in
     return c)
```

At `give_console`'s definition the walker records:

- a latent site with `latent_in_function = "Mod.give_console"`,
  handler arms `[(Console, Discharge); (Logger, Forward)]`, `in_lb = None`.

At each outer call it records a `call_site` record with the argument's
services lb. The analyzer joins:

- Call A: `in_lb = {Console}`, `out_lb = {Logger}` (the Logger forward
  survives). `grew = {Logger}`, `Logger` arm is Forward, **finding at A**.
- Call B: `in_lb = {Console, Logger}`, `out_lb = {Logger}` (Console
  discharged). `grew = {}`, silent.

Same wrapper, two different verdicts, each one landing at the right place.

---

## 7. Architecture

Two binaries, one contract:

```
                  ┌───────────────────────────┐
  .cmt files ───▶ │   hamlet-lint-extract     │
                  │   (compiler-libs-facing)  │
                  └─────────────┬─────────────┘
                                │  ND-JSON on stdout
                                ▼
                  ┌───────────────────────────┐
                  │   hamlet-lint             │
                  │   (pure OCaml, §2.3 rule) │
                  └─────────────┬─────────────┘
                                │  pretty report on stdout
                                ▼
                            exit 0 / 1
```

`hamlet-lint-extract` (directory `extract/`) is the only part of the
project that touches `compiler-libs`. Everything that might drift across
OCaml minors is isolated in `extract/compat.ml`: row lower-bound
extraction, `Path.t` printing, location conversion, and the effect-type
parameter splitter. When a future OCaml release breaks something, exactly
one file is expected to change.

`hamlet-lint` (directory `analyzer/`) is pure OCaml. It reads ND-JSON
records, runs the §4 rule, and prints findings. It does not link against
`compiler-libs`, so it builds unchanged against any OCaml version the rest
of the repo compiles on, and so its tests can be written purely in terms of
the schema without needing a compiled fixture.

`hamlet_lint_schema` (directory `schema/`) is the shared contract:
the OCaml types in `schema.ml` are the single source of truth and both
binaries encode/decode the same definitions.

---

## 8. The ND-JSON contract

Output is **newline-delimited JSON** — one self-contained object per line
with a `"kind"` discriminator. ND-JSON streams, concatenates trivially across
parallel `.cmt` processing, and lets the analyzer process records
incrementally.

The first record of any output is a **header**:

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"canonical"}
```

`schema_version` is a single integer; the analyzer rejects any value other
than the major version it was compiled against, exiting with code 2.
`ocaml_version` is the extractor's compile-time `Sys.ocaml_version`, echoed
for diagnostic purposes. `generated_at` is `"canonical"` when the extractor
is run with `--canonical` (stable snapshot mode) and `"runtime"` otherwise.

Subsequent records are **concrete_site**, **latent_site**, or **call_site**:

### concrete_site

```json
{
  "kind": "concrete_site",
  "loc":        {"file":"app.ml","line":42,"col":2},
  "effect_loc": {"file":"app.ml","line":42,"col":14},
  "combinator": "Hamlet.Combinators.catch",
  "services": null,
  "errors": {
    "in_lower_bound":  ["NotFound"],
    "out_lower_bound": ["Forbidden","Timeout"],
    "handler": {
      "has_wildcard_forward": false,
      "arms": [
        {"tag":"NotFound", "action":"Discharge","body_introduces":[],"loc":{"file":"app.ml","line":43,"col":6}},
        {"tag":"Timeout",  "action":"Forward",  "body_introduces":[],"loc":{"file":"app.ml","line":44,"col":6}},
        {"tag":"Forbidden","action":"Forward",  "body_introduces":[],"loc":{"file":"app.ml","line":45,"col":6}}
      ]
    }
  }
}
```

- `loc` — the application site, where the finding will land.
- `effect_loc` — the input effect expression, used to point the report at
  the right argument when the combinator is reformatted multi-line.
- `combinator` — exactly one of the eight strings from the §3 table, or the
  PPX form `"<Mod>.Tag.provide"`.
- `services` / `errors` — row records. Exactly one is populated on any given
  call; the other is `null`. A future combinator touching both rows would
  populate both and the analyzer would run the rule independently on each.
- `in_lower_bound` — the `Rpresent` tags of the row at the input, read
  through `Types.row_repr`. Absent and `Reither` tags are deliberately not
  part of the lower bound.
- `out_lower_bound` — same, at the output.
- `handler.has_wildcard_forward` — §4.2.
- `handler.arms[*].tag` — the polymorphic variant label, without the
  leading backtick.
- `handler.arms[*].action` — `"Discharge"` or `"Forward"`.
- `handler.arms[*].body_introduces` — the lower bound of `'e` read off the
  arm body's inferred `exp_type`. Used for §4.1 case (b). Always `[]` for
  services arms (the body is a `provide_result`, which is not an effect) and
  in v0.1 also `[]` for errors arms (see §12, "Known limits").

### latent_site

Same shape as `concrete_site` but with `"kind":"latent_site"`,
`in_lower_bound` set to `null` on every row record, and an extra field
`"latent_in_function":"<Path.t>"` identifying the enclosing function. Must
be joined against one or more `call_site` records for the same path.

### call_site

```json
{
  "kind": "call_site",
  "function_path": "App.give_console",
  "loc":     {"file":"app.ml","line":101,"col":10},
  "arg_loc": {"file":"app.ml","line":101,"col":24},
  "arg_services_lb": ["Console"],
  "arg_errors_lb":    null
}
```

One record per `Texp_apply` of a function whose definition has at least one
latent handler-site inside it. The analyzer looks up these by
`function_path` when it processes a latent site and reads the argument's
row lb's from this record.

### Canonical mode

`hamlet-lint-extract --canonical` sorts concrete sites by
`(file, line, col)` and sets `generated_at="canonical"`, making the output
stable across runs. Use it for snapshot tests. The normal mode preserves
the traversal order and embeds a real timestamp.

---

## 9. Versioning model

hamlet-lint is published as one opam package per `(hamlet, ocaml-minor)`
pair. Package names look like `hamlet-lint.<hamlet>-<ocaml>`, e.g.
`hamlet-lint.0.1.0-5.4`: hamlet version before the dash, OCaml minor
after. Each package pins `hamlet = <hamlet>` exactly.

### 9.1 Single trunk, not release branches

**There is only one hamlet-lint codebase: `main`.** It knows how to
recognise every supported hamlet. No release branches, no parallel trees.

Package versions are labels of packaging, not git tags over divergent
source trees. When you see `hamlet-lint.0.2.0-5.4` and `hamlet-lint.0.3.0-5.4`
side by side in opam-repository, both were built from the *same* `main`
commit — the only differences are which `hamlet.X.Y.Z` the opam file
pins and the fixture compilation target. A walker fix landed on `main`
benefits every subsequent release automatically.

### 9.2 Two release axes, both mandatory

- **hamlet version.** Lockstep with hamlet. When `hamlet.X.Y.Z` is
  published, hamlet-lint publishes `X.Y.Z-<ocaml>` for every supported
  OCaml minor. No version ranges on hamlet: each package pins exactly
  one hamlet version, trading occasional no-op releases for zero
  ambiguity on compatibility.
- **OCaml minor.** Required because the extractor links
  `compiler-libs`, whose `Types` / `Typedtree` / `Cmt_format` formats
  drift between minors with no semver guarantee. A binary must be built
  against the exact minor it analyses.

### 9.3 What a new hamlet release triggers

1. Run the linter's test suite on `main` against the new hamlet.
2. Fix the walker on `main` if hamlet renamed / added a combinator, or
   changed the shape of a matched API.
3. Publish `X.Y.Z-<ocaml>` for every supported OCaml, all from the
   current `main` commit.

If the walker needs no changes, the release is bump version → tag →
push: the workflow handles the per-OCaml matrix.

### 9.4 What a new OCaml minor triggers

1. Run the test suite against the new OCaml.
2. Fix the compat firewall in `extract/compat.ml` if needed.
3. Run a backfill workflow: for every past hamlet release, publish
   `X.Y.Z-<new-ocaml>` from the current `main` commit.

You never go back to old linter code. `main` always moves forward;
release plumbing re-packages it under many labels.

### 9.5 Where the plumbing lives

- `extract/compat.ml` — compiler-libs firewall; one file per
  `Types.*`/`Typedtree.*` API that drifts across minors.
- `release/hamlet-lint.opam.tmpl` — release-time opam template with
  `%%VERSION%%` / `%%HAMLET_VERSION%%` / `%%OCAML_MIN%%` / … placeholders;
  kept in `release/` so dune doesn't pick it up as a `.opam.template`.
- `hamlet-lint.opam` — dev-time opam file auto-generated by dune; never
  shipped, the release workflow uses the template.
- `CHANGES-5.4.md` — per-OCaml-target changelog.
- `.github/workflows/ci.yml` — dogfood matrix and build-time hamlet
  selection (`HAMLET_SOURCE`, see `SWITCH-TO-OPAM.md`).

Operational procedure for releases in `docs/RELEASING.md`.

---

## 10. How to add a new test case

Two layers:

- **Rule tests** in `test/test_rule.ml` drive `Rule.check_*` directly
  with hand-built schema records. The right place for rule semantics
  (wildcard suppression, body-introducer case, latent join) — no
  compiler-libs, no fixtures. Use `mk_services_site`/`mk_errors_site`/
  `mk_arm` helpers and assert via `check_tags`.
- **End-to-end fixtures** in `test/cases/<name>/`, exercised by
  `test/test_e2e.ml`. See `test/cases/README.md` for the
  fixture layout and the `make -C lint run/ndjson/debug FIXTURE=<name>`
  helpers.

Run `dune runtest`; regenerate snapshots with `dune promote`.

---

## 11. How to add support for a new combinator

If Hamlet grows a ninth handler-style combinator, hook it in like this:

1. Add a constructor to `combinator_kind` in `schema/schema.ml` and
   update the `combinator_kind_to_string`/`_of_string` pair symmetrically.
2. Extend `match_combinator` in `extract/walker.ml` with a suffix
   match resolving the dotted name to the new kind.
3. Teach `concrete_of_apply` how to split the new combinator's arguments:
   subject effect, handler, lambdas to peel, and which row is touched.
4. If the body shape is novel (not `give`/`need`, `failure`/`success`, or
   a pure variant), add a `classify_<new>_arm` and wire it into
   `arms_of_cases`.
5. Add a rule test to `test_rule.ml` and an e2e fixture under
   `test/cases/<new_combinator>/` covering stale and clean cases.
6. Update the §3 table with the new row.

---

## 12. Known limits (v0.1)

### Instrumented

- Seven combinators from §3 (all except row 2 `<Mod>.Tag.provide`, which
  is recognised but emits no site — it is never stale by construction).
  Handlers may be inline `function`, let-bound, alias chains, nested
  `let … in` RHS, or cross-module `Pdot`; resolution depth 5, global
  table pre-built from every cmt in the load set. Aliasing a combinator
  itself (`let my_provide = Combinators.provide`) is handled via a
  structure pre-scan.
- Latent wrapper sites with multi-level chains, mutual recursion, and
  cross-module joining. Chains are resolved by a monotone fixed-point
  capped at `|fns_in_load_set| + 10` passes (the process exits non-zero
  if the cap is ever hit). Latent sites are keyed by the canonical
  dotted path of the enclosing function; two modules that each define a
  `wrap` stay distinct.
- §4.1 case (b) legitimate-body-introducer suppression on errors arms,
  driven by a syntactic scan for direct `Combinators.failure (\`Tag …)`,
  the PPX `<Mod>.Errors.make_<name>` constructor form (mapped by
  strip-prefix-and-capitalise: `make_foo_error` → `` `Foo_error ``), and
  inline `Combinators.try_catch f (fun _ -> \`Tag)` exn handlers. The
  scanner also follows transitive helper calls (same-module top-level,
  nested `let`, and cross-module), capped at depth 5 with a per-scan
  visited set so mutually recursive helpers terminate. On truncation the
  scanner contributes nothing for that path. Each arm's own pattern tags
  are subtracted from its `body_introduces` so `` `T -> failure `T``
  remains reportable as case (a).

### Not instrumented (deferred to v0.2)

- Handlers flowing through data structures (record fields, hashmaps,
  functor arguments, closures returned from functions). Requires a
  small data-flow analysis.

The walker always fails in the safe direction: unrecognised shapes are
skipped silently (`HAMLET_LINT_DEBUG=1` for stderr diagnostics). False
negatives only; no false positives. See `CHANGES-lint-5.4.md` for the
per-version history.

---

## 13. License and issues

hamlet-lint is part of the Hamlet monorepo and ships under the same MIT
license (`LICENSE` in the repository root). File issues at
<https://github.com/hamlet-org/hamlet/issues>; tag them `lint:` so they
don't get mixed with core-library tickets.
