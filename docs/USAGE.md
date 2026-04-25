# Using hamlet-lint

End-user reference: install, configure, run, integrate. Rule semantics
in `RULE.md`. Architecture in `ARCHITECTURE.md`.

## 1. Install

```bash
opam install hamlet-lint
```

Packages versioned `<hamlet>~<ocaml>` (e.g. `hamlet-lint.0.2.0~5.4.1`).
Each pins the matching hamlet + OCaml patch exactly. Installs
`hamlet-lint-extract` and `hamlet-lint` on `PATH`.

As a project dev dep:

```
depends: [ "hamlet-lint" {with-dev-setup & = "0.2.0~5.4.1"} ]
```

## 2. Run

### With a config (recommended)

`.hamlet-lint.sexp` at project root:

```scheme
(targets _build/default/lib _build/default/bin)
(exclude _build/default/test)
(mode    fail)  ; or warn
```

Then:

```bash
dune build
hamlet-lint-extract | hamlet-lint
```

Both binaries walk up from cwd to find the config; paths resolve
against the config file's directory. Extractor reads `targets` /
`exclude`; analyzer reads `mode`.

| Key       | Type            | Required | Default | Meaning                       |
|-----------|-----------------|----------|---------|-------------------------------|
| `targets` | list of paths   | yes      | —       | Directories or `.cmt` files   |
| `exclude` | list of paths   | no       | `()`    | Path prefixes to skip         |
| `mode`    | `fail` / `warn` | no       | `fail`  | `warn` forces analyzer exit 0 |

Unknown top-level forms are rejected.

### Without a config

```bash
hamlet-lint-extract _build/default/lib | hamlet-lint
```

## 3. Exit codes

| Code | Meaning                                          |
|------|--------------------------------------------------|
| 0    | Clean, or findings with `--warn-only` / `warn`   |
| 1    | Findings present (default)                       |
| 2    | Malformed input or config error                  |

## 4. Flags

**`hamlet-lint-extract`**: `[FILES|DIRS]` (positional),
`--exclude PATH` (repeatable), `--config FILE`, `--canonical` (sort
records).

**`hamlet-lint`**: `-i FILE` / `--input FILE` (read from file),
`-w` / `--warn-only` (always exit 0; overrides config).

## 5. CI

```yaml
- uses: ocaml/setup-ocaml@v3
  with: { ocaml-compiler: "5.4" }
- run: opam install . --deps-only --with-dev-setup
- run: opam install hamlet-lint
- run: make build
- run: make lint
```

For non-blocking adoption: `(mode warn)` in config, or
`hamlet-lint-extract | hamlet-lint --warn-only`.

## 6. Reading findings

```
File "src/foo.ml", line 42, characters 14-14:
  hamlet-lint WARNING: catch handler declares [%hamlet.te ...] tags not present in upstream.
    declared  : [Console_error; Connection_error; Query_error]
    upstream  : [Console_error]
    extra tags not emitted : [Connection_error; Query_error]
```

Two typical fixes:

1. Annotation too wide → shrink it to upstream's actual tags.
2. Upstream missing a producer → add the `summon` / `failure` for
   the declared tags.

## 7. Troubleshooting

- **`missing header record`**: analyzer was fed something that isn't
  extractor output. Either you forgot the pipe, or the extractor
  crashed before writing. Check stderr; extractor exits 2 on every
  controlled error path.
- **`unsupported schema_version`**: extractor and analyzer come from
  different installs. Reinstall both.
- **`no available version`** on `opam install`: your OCaml patch has
  no release yet. `opam list -A hamlet-lint`.
- **Expected finding silent**: usually inline upstream — see
  `LIMITATIONS.md` §1.

## 8. Known limits

See `LIMITATIONS.md`. Headlines:

- Inline upstream from non-monitored ops (e.g. `let*`/`chain`) →
  bind first.
- Pre-installed opam libs are invisible (`.cmti` only, walker needs
  `.cmt`).
- Aliased Hamlet primitives in handler arms not followed (use
  canonical paths).
