# hamlet-lint

A semantic linter for the [Hamlet](https://github.com/hamlet-org/hamlet)
effect system. It walks the typed AST of your compiled project and
hunts one specific bug: **retroactive widening** in the handlers of
Hamlet's seven handler-driven row combinators —
`Hamlet.Combinators.{catch, map_error, provide}` and
`Hamlet.Layer.{catch, provide_to_effect, provide_to_layer, provide_merge_to_layer}`.

---

## 1. What it catches

Hamlet expresses a computation's required services and possible
errors as two open polymorphic variant rows on
`('a, 'e, 'r) Hamlet.t`. When a handler is annotated with
`[%hamlet.te ...]` (errors universe) or `[%hamlet.ts ...]` (services
universe), OCaml's covariant subtyping silently widens upstream's row
to make it match the handler's universe — even when upstream
provably never carries some of those tags. The bug is invisible at
compile time:

```ocaml
let eff =
  let* (module C) = Console.Tag.summon () in
  C.print_endline "go"   (* upstream row : [ Console_error ] *)

let _ =
  catch eff
    ~f:(fun (x : [%hamlet.te Console_error, Connection_error, Query_error]) ->
        match x with [%hamlet.propagate_e] -> .)
```

The handler claims to cover `Console_error`, `Connection_error`,
`Query_error`. Upstream emits only `Console_error`. The two extra
tags are dead weight: callers must now prove they handle errors that
the program provably cannot raise. hamlet-lint flags both extras.

The same shape on the services row uses `[%hamlet.ts ...]` and
`Hamlet.Combinators.provide` (or one of the `Layer.provide_to_*`
variants). The one-line rule:

> *for every call to a monitored combinator, the tag set declared
> by the handler's `[%hamlet.te ...]` / `[%hamlet.ts ...]` annotation
> must be a subset of the tag set actually carried by the upstream
> effect's row at the relevant slot.*

`docs/RULE.md` states this formally, lists all 7 monitored
combinators with their slot/arity, and enumerates every handler /
callee shape the linter recognises.

OCaml's row subtyping cannot reject this at compile time given
hamlet's covariant design (see `docs/ARCHITECTURE.md` §2 for the
type-system explanation). The linter operates on the `.cmt` files
the typechecker emits, so the only requirement is a successful
compilation.

---

## 2. Versioning model

hamlet-lint is published as one opam package per
`(hamlet, ocaml-patch)` pair. Package names look like
`hamlet-lint.<hamlet>~<ocaml>`, e.g. `hamlet-lint.0.2.0~5.4.1`. Each
package pins `hamlet = <hamlet>` and `ocaml = <ocaml>` exactly. The
tilde follows the opam convention for compiler-tied variant suffixes
(cf. `ppxlib.0.38.0~5.5preview`).

**One codebase.** There is only one hamlet-lint source tree: `main`.
Package version strings are labels of packaging, not lines of
divergent source history. When `hamlet-lint.0.2.0~5.4.1` and
`hamlet-lint.0.3.0~5.4.1` sit side by side on opam-repository, both
were built from the same `main` commit; the only differences are the
pinned hamlet version and the fixture compilation target.

**Two release triggers, asymmetric matrix.** Every hamlet release
(lockstep) and every newly supported OCaml patch (compat firewall,
since the extractor links `compiler-libs`) triggers a release pass
from the current `main`. New hamlet: publish one package per
supported OCaml. New OCaml: publish one package for the **latest**
hamlet only — past hamlet releases are NOT backfilled. A user pinned
to an older `hamlet.X.Y.Z` who upgrades OCaml must also upgrade
hamlet to get linter coverage on the new patch; existing
`<old-hamlet>~<old-ocaml>` packages stay available unchanged. `main`
only moves forward. The firewall lives in a single
`cppo`-preprocessed file (`extract/compat.cppo.ml`) with a top-level
`#error` guard. v0.2 pins OCaml 5.4.1 exactly.

See `docs/RELEASING.md` for the operational procedure and
`docs/ARCHITECTURE.md` for why `compiler-libs` forces the OCaml axis.

---

## 3. Quick start

```sh
dune build
hamlet-lint-extract _build/default | hamlet-lint
```

Clean runs print nothing and exit 0. Findings print a multi-line
warning per call site (location + declared / upstream / extra tags)
and exit 1. Exit 2 indicates malformed ND-JSON input — typically a
`schema_version` mismatch between the two binaries. For install,
config, flags, and CI integration see `docs/USAGE.md`.

---

## 4. Architecture in one paragraph

Two binaries. `hamlet-lint-extract` links `compiler-libs`, walks the
`.cmt` files for every monitored combinator application
(`Combinators.{catch, map_error, provide}`, all four
`Layer.{catch, provide_to_*}`), extracts the handler's declared
universe and upstream's row, and emits one ND-JSON record per
recognised call on stdout.
`hamlet-lint` is OCaml-version-agnostic: it reads the ND-JSON
stream, applies the rule (declared \\ upstream ≠ ∅), and prints
human-readable findings. The wire schema is versioned (`schema/`)
so the analyzer can refuse mismatched input loudly. See
`docs/ARCHITECTURE.md`.

---

## 5. Documentation

- `docs/USAGE.md`: install, config, CLI flags, CI integration,
  finding format, troubleshooting.
- `docs/RULE.md`: the formal rule, supported handler / callee
  shapes, slot mapping (`'e` vs `'r`), wire format.
- `docs/LIMITATIONS.md`: what hamlet-lint does NOT catch today and
  why (notably: inline upstream without a let-binding).
- `docs/ARCHITECTURE.md`: why `.cmt`, two-binary split, ND-JSON
  contract, walker coverage details.
- `docs/RELEASING.md`: release workflow, CHANGELOG model,
  latest-hamlet-only policy on new OCaml patches.
- `docs/CONTRIBUTING.md`: dev setup, adding tests, adding new
  OCaml targets.
- `CHANGELOG.md`: chronological history.

---

## 6. License and issues

hamlet-lint ships under the MIT license (`LICENSE` in the repository
root). File issues at
<https://github.com/hamlet-org/hamlet-lint/issues>.
