# hamlet-lint

A semantic linter for the [Hamlet](https://github.com/hamlet-org/hamlet)
effect system. It walks the typed AST of your compiled project and
hunts one very specific bug: **phantom row growth** caused by stale
forwarding arms in the handlers of Hamlet's row-discharging
combinators.

---

## 1. What it catches

Hamlet expresses a computation's required services and possible
errors as two open polymorphic variant rows on
`('a, 'e, 'r) Hamlet.t`. Both rows grow as effects compose and are
discharged by a small set of handler-style combinators. The bug
hamlet-lint catches is the case where a forwarding arm resurrects a
tag that the input effect never carried:

```ocaml
let prog () : (int, [> `NotFound ], 'r) Hamlet.t = failure `NotFound

let handled () =
  catch (prog ()) ~f:(function
    | `NotFound  -> success 0
    | `Timeout   -> failure `Timeout
    | `Forbidden -> failure `Forbidden)
```

`prog`'s errors row has exactly one inhabitant: `` `NotFound ``. The
handler discharges it and recovers to `success 0`, so you would
expect `handled` to have the empty errors row. Instead OCaml infers
`[> `Forbidden | `Timeout ]`: the two forwarding arms introduce
`` `Timeout `` and `` `Forbidden `` into the output row out of
nowhere. Any caller of `handled` now has to prove it can handle
errors that the program provably cannot raise. That is phantom row
growth, and hamlet-lint reports both arms as stale.

The one-line rule: *every tag that appears on the output row but not
on the input row must be attributable to a real introducer on the
path; if the only thing adding it is a forwarding arm that
pattern-matches it, the arm is stale.* `docs/RULE.md` states this
formally and lists the eight combinators where it applies.

---

## 2. Versioning model

hamlet-lint is published as one opam package per
`(hamlet, ocaml-minor)` pair. Package names look like
`hamlet-lint.<hamlet>-<ocaml>`, e.g. `hamlet-lint.0.1.0-5.4`. Each
package pins `hamlet = <hamlet>` exactly and targets one OCaml minor.

**One codebase.** There is only one hamlet-lint source tree: `main`.
Package version strings are labels of packaging, not lines of
divergent source history. When `hamlet-lint.0.2.0-5.4` and
`hamlet-lint.0.3.0-5.4` sit side by side on opam-repository, both
were built from the same `main` commit; the only differences are the
pinned hamlet version and the fixture compilation target.

**Two mandatory axes.** Every hamlet release (lockstep) and every
OCaml minor (compat firewall, since the extractor links
`compiler-libs`) triggers a release pass from the current `main`. New
hamlet: publish one package per supported OCaml. New OCaml: backfill
one package per past hamlet. `main` only moves forward. The firewall
lives in a single `cppo`-preprocessed file
(`extract/compat.cppo.ml`) with a top-level `#error` guard. v0.1
pins OCaml 5.4.1 exactly.

See `docs/RELEASING.md` for the operational procedure and
`docs/ARCHITECTURE.md` for why `compiler-libs` forces the OCaml axis.

---

## 3. Quick start

```sh
dune build
hamlet-lint-extract _build/default | hamlet-lint
```

Clean runs print `no findings` and exit 0. Findings print
`file:line:col: stale forwarding arm …` and exit 1 (exit 2 on input
error, typically a `schema_version` mismatch between the two
binaries). For install, config, flags, and CI integration see
`docs/USAGE.md`.

---

## 4. Documentation

- `docs/USAGE.md`: install, config, CLI flags, CI integration,
  finding format, troubleshooting.
- `docs/RULE.md`: the eight combinators and the formal rule (cases
  a, b, c; wildcard suppression; latent sites).
- `docs/LIMITATIONS.md`: what hamlet-lint does NOT catch today and
  why (data-flow handlers, opam dependencies, complex arm bodies,
  OCaml and hamlet version coupling).
- `docs/ARCHITECTURE.md`: why `.cmt`, two-firewall model,
  concrete/latent sites, analyzer pseudocode, ND-JSON contract,
  walker coverage details.
- `docs/RELEASING.md`: release workflow, CHANGELOG model, backfill
  passes.
- `docs/CONTRIBUTING.md`: dev setup, adding tests and combinators,
  adding new OCaml targets.
- `CHANGELOG.md`: chronological walker and analyzer history.

---

## 5. License and issues

hamlet-lint ships under the MIT license (`LICENSE` in the repository
root). File issues at
<https://github.com/hamlet-org/hamlet-lint/issues>.
