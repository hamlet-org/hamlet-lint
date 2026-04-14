# hamlet-lint architecture

Internal reference for the walker, the analyzer, and the wire contract
between them. For the one-line rule and the eight combinators see
`README.md`; for install / config / CI see `USAGE.md`; for release
mechanics see `RELEASING.md`.

---

## 1. Why `.cmt` files

Row lower bounds exist only after type inference, so the linter cannot
be a `ppxlib` PPX (PPX runs before inference). `.cmt` files are the
typed AST the compiler emits under `_build/default/**/*.cmt`;
`compiler-libs` provides `Cmt_format.read_cmt` to parse them back. The
tool is therefore version-locked against `compiler-libs` (`Typedtree`,
`Types`, and friends drift across OCaml minors without semver);
`README.md` §9 covers the version-support policy.

### 1.1 `.cmt` vs `.cmti`

The extractor walks `.cmt` only, never `.cmti`:
`Filename.check_suffix f ".cmt"` in `extract/main.ml` — a `.cmti` file
does not satisfy that check because the suffix comparison is
length-strict. Consequence: **the linter sees through signature
abstraction** — an opaque `.mli` that hides or narrows a row does not
hide the implementation's raw `provide` / `catch` / `map_error` calls
from hamlet-lint.

Three `.mli` cases, in decreasing order of how much value the linter
adds:

- **No `.mli`.** The compiler infers the general type with the phantom
  tag. The code type-checks, the bug is silent, the linter is the
  only thing that catches it — the common case.
- **`.mli` with a free row variable.** Signature coercion admits the
  contaminated row; the linter catches it, the compiler does not.
- **`.mli` with a tight concrete row.** Signature coercion itself
  rejects the impl — compiler error before the linter runs. Good
  defence-in-depth, nothing for the linter to add.

### 1.2 Pre-installed libraries are invisible

opam ships `.cmi` / `.cmti` / `.cmxa` into `_opam/lib/<pkg>/` but not
`.cmt`, so anything installed from opam is invisible to the walker.
This is shared with every typed-AST tool (merlin, mdx, ppxlib linters,
…).

Consequence for **library authors**: if your package uses Hamlet
internally and you want a phantom-row-growth guarantee, run hamlet-lint
in your own CI before releasing. Downstream users cannot lint it for
you.

For **library users**: the linter analyses your own code and passes
silently over opam dependencies. You still catch stale forwards in
your code that use a dependency's services or errors (those live in
your own `.cmt`s); you do not catch stale forwards inside the
dependency itself.

---

## 2. Concrete vs latent sites

A call like

```ocaml
catch prog ~f:(function ...)
```

is **concrete** when the walker can read `in_lb` directly off `prog`'s
inferred type. But when the programmer writes a wrapper

```ocaml
let wrap eff = catch eff ~f:(function ...)
```

the handler is syntactically present at `wrap`'s definition but the
input effect is a free row variable parameter. The walker cannot
compute `grew` at the definition site — it depends on which `eff` the
caller passes in. So the extractor records a **latent site** keyed by
the enclosing function's `Path.t`, and every `Texp_apply` of that
function as a **call site**. The analyzer joins latent arms against
each call site's argument row lb; the finding always lands at the
outer call, never at the handler's definition (whether a mixed
discharge/forward handler is buggy depends on which `eff` the caller
passes, and different calls can differ).

Wrapper chains iterate naturally until they bottom out at a concrete
call. Latent sites whose function has zero calls in the cmt set are
silently dropped.

### 2.1 A worked example

```ocaml
(* Wrapper function: handler is here, input effect is a free parameter *)
let give_console eff =
  Combinators.provide
    (function
      | #Console.Tag.r as w -> Console.Tag.give w "stdout"
      | #Logger.Tag.r  as r -> Combinators.need r)
    eff

(* Call site A: eff has services lb = [Console] *)
let a () = give_console (Combinators.summon Console.Tag.key `Console)

(* Call site B: eff has services lb = [Console; Logger] *)
let b () =
  give_console
    (let* c = Combinators.summon Console.Tag.key `Console in
     let* _ = Combinators.summon Logger.Tag.key  `Logger  in
     return c)
```

At `give_console`'s definition the walker records:

- a latent site with `latent_in_function = "Mod.give_console"`,
  handler arms `[(Console, Discharge); (Logger, Forward)]`,
  `in_lb = None`.

At each outer call it records a `call_site` record with the argument's
services lb. The analyzer joins:

- Call A: `in_lb = [Console]`, `out_lb = [Logger]` (the Logger forward
  survives). `grew = [Logger]`, `Logger` arm is Forward,
  **finding at A**.
- Call B: `in_lb = [Console; Logger]`, `out_lb = [Logger]` (Console
  discharged). `grew = []`, silent.

Same wrapper, two different verdicts, each one landing at the right
place.

---

## 3. The analyzer in pseudocode

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

Implementation in `analyzer/rule.ml`.

---

## 4. Two binaries, one contract

```
                  ┌───────────────────────────┐
  .cmt files ───▶ │   hamlet-lint-extract     │
                  │   (compiler-libs-facing)  │
                  └─────────────┬─────────────┘
                                │  ND-JSON on stdout
                                ▼
                  ┌───────────────────────────┐
                  │   hamlet-lint             │
                  │   (pure OCaml, the rule)  │
                  └─────────────┬─────────────┘
                                │  pretty report on stdout
                                ▼
                            exit 0 / 1
```

`hamlet-lint-extract` (directory `extract/`) is the only part of the
project that touches `compiler-libs`. Everything that might drift
across OCaml minors is isolated in `extract/compat.cppo.ml`: row
lower-bound extraction, `Path.t` printing, location conversion, and
the effect-type parameter splitter. The file is preprocessed by `cppo`
with `-V OCAML:%{ocaml_version}`, producing `compat.ml` in the build
dir; version-sensitive bodies go behind `#if OCAML_VERSION >= (5, 5, 0)`
branches. A top-of-file `#error` guard asserts the supported versions
— v0.1 pins OCaml 5.4.1 exactly, so a wrong switch fails the
preprocess, not the typechecker. When a future OCaml release breaks
something, exactly one file is expected to change.

`hamlet-lint` (directory `analyzer/`) is pure OCaml. It reads ND-JSON
records, runs the rule, and prints findings. It does not link against
`compiler-libs`, so it builds unchanged against any OCaml version the
rest of the repo compiles on, and its tests can be written purely in
terms of the schema without needing a compiled fixture.

`hamlet_lint_schema` (directory `schema/`) is the shared contract:
the OCaml types in `schema.ml` are the single source of truth and both
binaries encode/decode the same definitions.

`hamlet_lint_config` (directory `config/`) is a small library that
parses `.hamlet-lint.sexp` project config files. Both binaries read
it independently (the extractor picks up `targets` and `exclude`; the
analyzer picks up `mode`). No process spawning between them.

---

## 5. The ND-JSON contract

Output is **newline-delimited JSON** — one self-contained object per
line with a `"kind"` discriminator. ND-JSON streams, concatenates
trivially across parallel `.cmt` processing, and lets the analyzer
process records incrementally.

The first record of any output is a **header**:

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"canonical"}
```

`schema_version` is a single integer; the analyzer rejects any value
other than the major version it was compiled against, exiting with
code 2. `ocaml_version` is the extractor's compile-time
`Sys.ocaml_version`, echoed for diagnostic purposes. `generated_at`
is `"canonical"` when the extractor is run with `--canonical` (stable
snapshot mode) and `"runtime"` otherwise.

Subsequent records are **concrete_site**, **latent_site**, or
**call_site**.

### 5.1 concrete_site

```json
{
  "kind": "concrete_site",
  "loc":  {"file":"app.ml","line":42,"col":2},
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
- `combinator` — exactly one of the strings from the `README.md` §3
  table, or the PPX form `"<Mod>.Tag.provide"`.
- `services` / `errors` — row records. Exactly one is populated on any
  given call; the other is `null`. A future combinator touching both
  rows would populate both and the analyzer would run the rule
  independently on each.
- `in_lower_bound` — the `Rpresent` tags of the row at the input, read
  through `Types.row_repr`. Absent and `Reither` tags are deliberately
  not part of the lower bound.
- `out_lower_bound` — same, at the output.
- `handler.has_wildcard_forward` — set when the handler has a `_ ->`
  forwarding arm. When true, the analyzer shortcuts the diff (the
  wildcard unifies `out_lb = in_lb`, so `grew` is empty by
  construction — explicit documentation that a forward-all is
  intentional).
- `handler.arms[*].tag` — the polymorphic variant label, without the
  leading backtick.
- `handler.arms[*].action` — `"Discharge"` or `"Forward"`.
- `handler.arms[*].body_introduces` — the lower bound of `'e` read
  off the arm body's inferred `exp_type`. Used for legitimate-body
  suppression. Always `[]` for services arms (the body is a
  `provide_result`, which is not an effect).

### 5.2 latent_site

Same shape as `concrete_site` but with `"kind":"latent_site"`,
`in_lower_bound` set to `null` on every row record, and an extra field
`"latent_in_function":"<Path.t>"` identifying the enclosing function.
Must be joined against one or more `call_site` records for the same
path.

### 5.3 call_site

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

One record per `Texp_apply` of a function whose definition has at
least one latent handler-site inside it. The analyzer looks these up
by `function_path` when it processes a latent site and reads the
argument's row lbs from this record.

### 5.4 Canonical mode

`hamlet-lint-extract --canonical` sorts concrete sites by
`(file, line, col)` and sets `generated_at="canonical"`, making the
output stable across runs. Use it for snapshot tests. The normal mode
preserves the traversal order and embeds a real timestamp.
