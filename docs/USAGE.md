# Using hamlet-lint

End-user reference: install, configure, run, integrate into CI.
For the release process see `RELEASING.md`; for the architecture and
rule semantics see `README.md`.

---

## 1. Install

```bash
opam install hamlet-lint
```

opam picks the right package for your active switch automatically.
Packages are versioned `<hamlet_version>-<ocaml_minor>`, e.g.
`hamlet-lint.0.1.0-5.4` is the linter for users of `hamlet.0.1.0` on
OCaml 5.4 (v0.1 supports 5.4.1 exactly). Each package pins its matching
hamlet version exactly.
Installs `hamlet-lint-extract` and `hamlet-lint` on `PATH`.

As a **project dev dependency**, pin the exact version matching the
hamlet release you depend on:

```
depends: [
  "hamlet-lint" {with-dev-setup & = "0.1.0-5.4"}
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
| `format`  | `pretty`        | no       | `pretty` | Reserved for future reporters          |

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
- `HAMLET_LINT_DEBUG=1` (env): stderr diagnostics for skipped sites.

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
src/foo.ml:42:14: stale forwarding arm for tag `Logger in services row:
  input effect has no such dependency, this arm resurrects it
  (Hamlet.Combinators.provide)
  arm at src/foo.ml:35:50
```

- First line: the location of the combinator call (`provide`,
  `catch`, `map_error`, `Layer.*`, or a `Tag.provide`).
- `arm at …`: the stale arm itself.

Three typical fixes:

1. The arm is dead; remove it (wrong copy-paste).
2. The input is missing a `summon` for the forwarded tag; add the
   real dependency.
3. The arm legitimately raises the tag via a helper the walker
   could not see; file a bug and use `--warn-only` as a workaround.

---

## 7. Troubleshooting

**`missing header record`**: the extractor produced empty output
(no `.cmt` files at the given paths) or you piped the wrong thing
to `hamlet-lint`. Check with
`hamlet-lint-extract _build/default/lib | head -1`: it should start
with `{"kind":"header"`.

**`no available version`** on `opam install`: your OCaml minor has
no hamlet-lint release yet. Check `opam list -A hamlet-lint` and
file an issue if you need your minor supported.

**Finding you expected is silent**: try `HAMLET_LINT_DEBUG=1
hamlet-lint-extract …` on stderr to see which sites the walker
skipped. The walker always fails in the safe direction: false
negatives on shapes it cannot analyse, zero false positives on the
shapes it understands.

---

## 8. Known limits (v0.1)

- Handlers flowing through data structures (record fields, hashmaps,
  closures returned from functions) are not analysed. Deferred to
  v0.2 which will add data-flow analysis. See `README.md` §12.
- Pre-installed opam libraries are invisible: the linter walks
  `.cmt` files, opam ships only `.cmti`. Library authors should run
  hamlet-lint in their own CI before releasing. See `README.md` §5.2.
