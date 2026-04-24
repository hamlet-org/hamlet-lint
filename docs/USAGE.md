# Using hamlet-lint

End-user reference: install, configure, run, integrate into CI.
For the rule semantics see `RULE.md`; for the architecture see
`ARCHITECTURE.md`; for the release process see `RELEASING.md`.

---

## 1. Install

```bash
opam install hamlet-lint
```

opam picks the right package for your active switch automatically.
Packages are versioned `<hamlet_version>~<ocaml_patch>`, e.g.
`hamlet-lint.0.2.0~5.4.1` is the linter for users of `hamlet.0.2.0`
on OCaml 5.4.1. Each package pins its matching hamlet and OCaml
versions exactly. Installs `hamlet-lint-extract` and `hamlet-lint`
on `PATH`.

As a **project dev dependency**, pin the exact version matching the
hamlet~ocaml releases you depend on:

```
depends: [
  "hamlet-lint" {with-dev-setup & = "0.2.0~5.4.1"}
]
```

Contributors pulling `opam install . --deps-only --with-dev-setup`
get it automatically; regular library users do not.

---

## 2. Run it

### 2.1 With a project config (recommended)

Create `.hamlet-lint.sexp` at your project root:

```scheme
(targets _build/default/lib _build/default/bin)
(exclude _build/default/test)
(mode    fail)  ; or warn
```

Then from the project root:

```bash
dune build
hamlet-lint-extract | hamlet-lint
```

Both binaries walk up from cwd to find the config; paths are resolved
against the config file's directory, not cwd, so subdirectory
invocations work. The extractor picks up `targets` and `exclude`; the
analyzer picks up `mode`.

Schema of the config:

| Key       | Type            | Required | Default  | Meaning                                |
|-----------|-----------------|----------|----------|----------------------------------------|
| `targets` | list of paths   | yes      | (none)   | Directories or `.cmt` files to walk    |
| `exclude` | list of paths   | no       | `()`     | Path prefixes to skip                  |
| `mode`    | `fail` / `warn` | no       | `fail`   | `warn` forces analyzer exit 0          |

Unknown top-level forms are rejected, so typos are caught loudly
rather than silently ignored.

### 2.2 Without a config (explicit pipeline)

```bash
dune build
hamlet-lint-extract _build/default/lib _build/default/bin | hamlet-lint
```

Same pipeline, paths given on the command line. Useful for one-off
invocations or when you do not want a config file in the repo.

### 2.3 Makefile target

```make
lint:
	dune build
	hamlet-lint-extract | hamlet-lint
```

With a config file, this is all you need. Without, hardcode the
paths:

```make
lint:
	dune build
	hamlet-lint-extract _build/default/lib | hamlet-lint
```

---

## 3. Exit codes

| Code | Meaning                                                 |
|------|---------------------------------------------------------|
| 0    | Clean run, or findings present with `--warn-only`/`warn`|
| 1    | Findings present (default)                              |
| 2    | Malformed input or config error                         |

---

## 4. Flags

**`hamlet-lint-extract`**

- `[FILES|DIRS]`: positional. Paths to walk.
- `--exclude PATH`: skip cmts whose absolute path starts with PATH.
  Repeatable.
- `--config FILE`: explicit config path; overrides auto-discovery.
- `--canonical`: sort records for stable snapshots.

**`hamlet-lint`**

- `-i`, `--input FILE`: read ND-JSON from FILE instead of stdin.
- `-w`, `--warn-only`: always exit 0. Overrides config's `mode`.

Full help: `hamlet-lint --help`, `hamlet-lint-extract --help`.

---

## 5. CI integration

```yaml
- uses: ocaml/setup-ocaml@v3
  with: { ocaml-compiler: "5.4" }
- run: opam install . --deps-only --with-dev-setup
- run: opam install hamlet-lint
- run: make build
- run: make lint
```

Exit 1 on findings fails the job.

For gradual adoption (findings visible but non-blocking), set
`(mode warn)` in the config file, or pass `--warn-only` explicitly:

```yaml
- run: hamlet-lint-extract | hamlet-lint --warn-only
```

---

## 6. Reading findings

```
File "src/foo.ml", line 42, characters 14-14:
  hamlet-lint WARNING: catch handler declares [%hamlet.te ...] tags not present in upstream.
    declared  : [Console_error; Connection_error; Query_error]
    upstream  : [Console_error]
    extra tags not emitted : [Connection_error; Query_error]
```

- First line: the location of the `catch` / `provide` call.
- `declared`: the handler's declared tag universe (from
  `[%hamlet.te ...]` for catch, `[%hamlet.ts ...]` for provide).
- `upstream`: tags actually carried by the upstream effect's row at
  the relevant slot.
- `extra tag(s) not emitted`: `declared \ upstream` — the tags the
  handler claims to cover that upstream provably does not raise /
  require.

Two typical fixes:

1. The annotation is wider than it should be: shrink it to the tags
   upstream actually carries.
2. Upstream is meant to carry those tags but a `summon` / `failure`
   for them is missing: add the real producer.

---

## 7. Troubleshooting

**`missing header record`**: the analyzer was fed something that
isn't extractor output. The extractor always emits a `header` line
first, even when no `.cmt` files matched, so this means either you
forgot to pipe `hamlet-lint-extract` into `hamlet-lint`, or the
extractor crashed before writing anything (in which case extractor
stderr will tell you why; it exits 2 on every controlled error
path — missing inputs, unreadable directories, corrupt `.cmt`).
Check with `hamlet-lint-extract _build/default/lib | head -1`: it
should start with `{"kind":"header"`.

**`unsupported schema_version`**: the extractor and analyzer come
from different hamlet-lint installs. Re-install both to the same
version.

**`no available version`** on `opam install`: your exact OCaml patch
has no hamlet-lint release yet (we patch-pin via tilde, e.g.
`hamlet-lint.0.2.0~5.4.1`). Check `opam list -A hamlet-lint` and
file an issue if you need your patch supported.

**Finding you expected is silent**: most often the upstream is
inline (no let-binding). Bind it first — see `LIMITATIONS.md` §1
for the workaround.

---

## 8. Known limits

See `LIMITATIONS.md` for the full list. Headline items:

- **Inline upstream** (no let-binding) is a documented false
  negative; bind upstream to expose the narrow row.
- **Pre-installed opam libraries** are invisible: opam ships only
  `.cmti`, the walker needs `.cmt`. Library authors should run
  hamlet-lint in their own CI before releasing.
- **Exotic handler shapes** beyond the five recognised ones (param
  pat, function-cases, scrutinee, named ident, single-apply build)
  are silently skipped.
