# hamlet-lint learning path

22 phases. Each sets up the problem before showing the mechanism, then
quotes real code from the source with `file:line` refs. Read in order;
total ~800 lines.

---

## Phase 0 — Mental model

hamlet-lint is a post-compile linter for **hamlet**, an OCaml
effect-system library. It reads the typed AST that the compiler emits
as `.cmt` files (one per source `.ml`), and looks for one specific
bug: **retroactive widening** in handlers passed to a small set of
combinators.

Why post-compile? Because the bug is a programmer mistake the OCaml
type system silently accepts (Phase 1 explains why). The check has to
happen on the typed AST, after the compiler has resolved every type
but before the user has shipped the code.

The whole tool runs as a 2-stage pipeline:

```sh
dune build && hamlet-lint-extract _build/default | hamlet-lint
```

Stage 1 (`hamlet-lint-extract`) reads the .cmt files and emits one
JSON object per suspicious call site. Stage 2 (`hamlet-lint`) reads
those JSON objects, applies a one-line rule, and prints findings.
Exit code 0 if clean, 1 if findings.

Total source: ~2K LOC OCaml across 5 small libraries.

---

## Phase 1 — The bug

Hamlet types every effectful computation as `('a, 'e, 'r) Hamlet.t`:

- `'a` = the success value's type;
- `'e` = an open polymorphic-variant row of the **errors** the
  computation might raise;
- `'r` = an open polymorphic-variant row of the **services** it
  requires.

When you pass a handler to one of the monitored combinators (e.g.
`Hamlet.Combinators.catch`), the handler's parameter is annotated
with `[%hamlet.te ...]` (errors) or `[%hamlet.ts ...]` (services).
After PPX expansion that annotation becomes a **closed**
polymorphic-variant type — a fixed, finite set of tags the handler
claims to cover.

Now the bug: OCaml's row subtyping is **covariant** on `'e` and `'r`.
If upstream produces `[ \`Console_error ]` and the handler claims
`[ \`Console_error | \`Database_error ]`, the type checker happily
widens upstream's row to match. **The compiler accepts it.** The
dead `` `Database_error `` never appears at runtime, but downstream
callers must still prove they can deal with it.

Concrete example, `test/cases/widening_cases.ml:18`:

```ocaml
(* case 2 — BAD: upstream emits only Console; handler declares Console + Database *)
let bad_catch_widening =
  let open Hamlet.Combinators in
  let eff =
    let* (module C) = Console.Tag.summon () in
    C.print_endline "go"   (* upstream's row : [ Console ] *)
  in
  catch eff ~f:(fun (x : [%hamlet.te Console, Database]) ->
      match x with [%hamlet.propagate_e] -> .)
```

`Database` is dead weight. hamlet-lint's job is to flag it.

---

## Phase 2 — Monitored combinators

Out of hamlet's full surface, 12 functions take a row-declaring
handler. They split by which row the handler refers to:

- **Errors row (`'e`)** — `catch`, `map_error`, `catch_filter`,
  `catch_cause`, `catch_cause_filter`, `Layer.catch`,
  `Layer.catch_cause`. The handler's annotation is `[%hamlet.te ...]`.
- **Services row (`'r`)** — `provide`, `provide_scope`,
  `Layer.provide_to_effect`, `Layer.provide_to_layer`,
  `Layer.provide_merge_to_layer`. The handler's annotation is
  `[%hamlet.ts ...]`.

Each combinator declares three things in addition to its slot:

- **`peel`** — how many outer handler parameters to skip before
  reading the row annotation. `peel = 0` for single-arg handlers
  (`catch ~f:(fun (x : [%hamlet.te ...]) -> ...)`); `peel = 1` for
  the curried handlers (`Layer.provide_to_*`, `provide_scope`) where
  the row sits on the **second** parameter
  (`~handler:(fun impl (x : [%hamlet.ts ...]) -> ...)`).
- **`handler_label`** — which labeled argument carries the row-typed
  callback. `~f` for the original `catch`/`map_error` family;
  `~handler` for `provide` and the `Layer.provide_*` family;
  `~filter` for the new filter combinators.
- **`wraps_in_cause`** — when the handler parameter is `'e Cause.t`
  rather than bare `'e` (the case for `catch_cause`,
  `catch_cause_filter`, `Layer.catch_cause`), the linter must strip
  one outer `Tconstr` layer to reach the polymorphic-variant row
  inside.

`extract/classify.ml:23` defines the descriptor:

```ocaml
type info = {
  slot : [ `Catch | `Provide ];
  peel : int;
  handler_label : string;     (* "f", "handler", "filter" *)
  wraps_in_cause : bool;
}

type classification = Match of info | Other
```

A single `paths : (string * info) list` and a fallback
`lasts : (string * info) list` (for the bare-name structural-fingerprint
case) drive every classification. Adding a new monitored combinator
is a single row in each list.

`` `Catch `` / `` `Provide `` is the linter's internal "which slot do
I look at?" tag. In the upstream type `('a, 'e, 'r) Hamlet.t`,
`` `Catch `` means slot 1 (`'e`), `` `Provide `` means slot 2 (`'r`).
The success type `'a` is never inspected.

---

## Phase 3 — Two binaries + ND-JSON

The tool is split into two executables connected by a wire format:

```
your-project/_build/default/**/*.cmt
        │
        ▼
hamlet-lint-extract       (links compiler-libs, OCaml-version-coupled)
        │  ND-JSON on stdout: 1 header line + N candidate lines
        ▼
hamlet-lint               (pure data; no compiler-libs)
        │
        ▼
findings on stdout, exit code 1 if any
```

Why this split?

- **Extract** must read `.cmt` files. That requires the
  `compiler-libs.common` library, which is shipped with OCaml itself
  and whose API changes across OCaml minor versions. So `extract` is
  heavy, OCaml-version-coupled, and the place where any compiler-libs
  drift is felt.
- **Analyze** just needs the candidates. It reads JSON, applies a
  list-set difference, and prints. No compiler-libs, no OCaml-version
  coupling, fast, easy to evolve in isolation.

Why ND-JSON (newline-delimited JSON, one object per line)?

- Streaming: extract can write candidates as it finds them, analyzer
  can read them one at a time.
- Trivially debuggable: pipe extract's output into `less`, `grep`,
  `jq`. `make ndjson FIXTURE=widening_cases` shows it.
- Schema-versioned: extract puts a header on the first line declaring
  `schema_version`; analyzer rejects mismatches with a clear error
  rather than crashing or producing garbage.

---

## Phase 4 — Wire schema

`schema/schema.ml:19`:

```ocaml
let schema_version = 1
type loc = { file : string; line : int; col : int }
type kind = Catch | Provide
type candidate = {
  loc : loc; kind : kind; combinator : string;
  declared : string list;   (* handler universe: what the annotation says *)
  upstream : string list;   (* upstream row tags: what reality actually carries *)
}
type header = { schema_version : int; ocaml_version : string; generated_at : string }
type record = Header of header | Candidate of candidate
```

A `record` is either the **header** (always first) or a **candidate**
(one per recognised call site).

Per-field meaning:

- `loc` — file/line/column where the combinator is called. Used in
  the report so editors can navigate to it.
- `kind` — which row was inspected: `Catch` (errors `'e`) or
  `Provide` (services `'r`). Determines how the analyzer phrases the
  finding.
- `combinator` — the short callee name (`catch`,
  `Layer.provide_to_effect`, ...). Lets the report tell the user
  which of the twelve monitored functions actually fired (since `kind`
  alone can't distinguish e.g. `catch` from `map_error`).
- `declared` — list of tag names the handler's annotation
  enumerates, in source order.
- `upstream` — list of tag names actually present in upstream's row
  at the relevant slot.

On the wire one record looks like:

```json
{"kind":"header","schema_version":1,"ocaml_version":"5.4.1","generated_at":"runtime"}
{"kind":"candidate","site_kind":"catch","combinator":"catch","loc":{"file":"x.ml","line":25,"col":11},"declared":["Console","Database"],"upstream":["Console"]}
```

If the analyzer sees no header or a different `schema_version`, it
exits 2 (input error) — distinguishing "tool bug / version mismatch"
from "findings present" (exit 1) and "clean" (exit 0).

---

## Phase 5 — The rule

Every other module exists to feed two lists into the rule. The rule
itself is six lines, `analyzer/rule.ml:25`:

```ocaml
let check (c : S.candidate) : finding option =
  let extra = List.filter (fun tag -> not (List.mem tag c.upstream)) c.declared in
  if extra = [] then None
  else Some { loc=c.loc; kind=c.kind; combinator=c.combinator;
              declared=c.declared; upstream=c.upstream; extra }
```

In set-theory terms: compute `declared \ upstream` (the tags the
handler claims that upstream doesn't actually emit). If that
difference is non-empty, the call is a finding; the elements of the
difference are the "extra" tags reported to the user.

Lists are tiny — single-digit length per call — so the quadratic
`List.filter`/`List.mem` is fine. No optimisation needed.

`analyze` (just below) is a fold: skip headers, run `check` on every
candidate, return the findings in input order.

---

## Phase 6 — Walking .cmt files

A `.cmt` file is the typed AST OCaml emits when you compile a module
with `-bin-annot` (which dune sets by default). It's a binary
serialisation of the entire `Typedtree.structure` for that module —
every expression with its type, every binding with its location. It's
the same data structure compiler tooling like merlin and ocamlformat
consume.

`hamlet-lint-extract` reads it via `Cmt_format.read_cmt`, which gives
back a `cmt_infos` record. The interesting field is `cmt_annots`,
which can be `Implementation str` (for a `.ml` file) or several other
variants (`.mli`, `.cmi`, etc. — none of which carry expression
bodies, so we skip them).

To traverse the structure we use the standard `Tast_iterator` from
compiler-libs. It's an open-recursive visitor: build a record where
the fields are visit functions, override the ones you care about,
call `iter.structure iter str` to walk.

`extract/walker.ml:100`:

```ocaml
let walk_cmt (path : string) (acc : S.candidate list ref) : unit =
  let cmt = try Cmt_format.read_cmt path
            with e -> raise (Bad_cmt (path, Printexc.to_string e)) in
  match cmt.cmt_annots with
  | Implementation str ->
      let check_expr self (e : expression) =
        (match e.exp_desc with
        | Texp_apply (fn, args) -> ... process_call ...
        | _ -> ());
        Tast_iterator.default_iterator.expr self e   (* always recurse *)
      in
      let iter = { Tast_iterator.default_iterator with expr = check_expr } in
      iter.structure iter str
  | _ -> ()
```

We override just `expr`. For every expression node, if it's a
function application (`Texp_apply`), inspect the callee — it might be
one of the 7 monitored combinators. After inspecting, we always call
the default visitor's `expr` so traversal continues into children
(the function's argument, the body, etc.).

If `read_cmt` fails (corrupt file, wrong magic number, truncated),
we wrap the exception into our own `Bad_cmt`, which the driver in
`extract/main.ml` catches and turns into a controlled exit-code-2
user error rather than an uncaught stack trace.

---

## Phase 7 — Classify

Now we have a `Texp_apply` node with a callee. The callee is a
`Path.t` pointing to some named value. Question: is this one of the
7 combinators we monitor?

Naive approach: compare `Path.name path` (the canonical dotted name
like `"Hamlet.Combinators.catch"`) to a hard-coded list. Works for
the direct-reference case `Hamlet.Combinators.catch eff ~f:H`.

It breaks the moment the user does
`let open Hamlet.Combinators in catch eff ~f:H`. After the
`let open`, the callee path inside the body is just `catch` — the
`Hamlet.Combinators.` prefix is gone. We'd miss it. Same problem with
`let module HC = Hamlet.Combinators in HC.catch eff ~f:H`.

So `classify_path` uses two strategies in order. `extract/classify.ml:118`:

```ocaml
let classify_path path val_type vd =
  let n = Path.name path in
  match List.assoc_opt n paths with
  | Some info -> Match info                      (* strategy 1: canonical match *)
  | None ->
      if not (path_root_is_hamlet path || val_loc_in_hamlet_surface vd) then Other
      else  (* strategy 2: bare-name + structural fingerprint *)
        let last = Path.last path in
        match List.assoc_opt last lasts with
        | Some info when mentions_hamlet_t val_type -> Match info
        | _ -> Other
```

Strategy 1 is the canonical-name match. Strategy 2 is the fallback:
take just the bare name (`Path.last`, e.g. `"catch"`), check that
this value provably came from hamlet, AND check that its type
structurally mentions a 3-arg `Hamlet.t` constructor:

```ocaml
let mentions_hamlet_t (ty : Types.type_expr) : bool =
  match Types.get_desc ty with
  | Tconstr (p, args, _) ->
      (Path.last p = "t" && List.length args = 3 && path_root_is_hamlet p)
      || List.exists go args
  | Tarrow (_, dom, codom, _) -> go dom || go codom
  ...
```

Why all these checks together? To prevent misclassification. If the
user has a local `let catch eff ~f = ...` helper named "catch", we
don't want to confuse it with the real combinator. The provenance
gate (`path_root_is_hamlet` checks the path is rooted in
`Hamlet`/`Hamlet__*`; `val_loc_in_hamlet_surface` checks the
definition site is in `hamlet.mli`/`hamlet.ml`) blocks user-defined
helpers from sneaking in. The structural fingerprint
(`mentions_hamlet_t`) is a second filter on top.

Returns `Match info | Other`. `Match info` means "yes, this is one of
ours; the descriptor in `info` tells the walker which slot to inspect,
how many handler parameters to peel, which labeled argument carries
the handler, and whether to descend through a `Cause.t` wrapper".
`Other` means "not interesting, skip".

---

## Phase 8 — Tags

OCaml's polymorphic variants — `[ \`Foo | \`Bar ]` — are typed as a
`Tvariant` node. The variant carries a list of fields (one per tag)
plus a `row_more` "tail" — because polymorphic-variant rows can be
**open** (extended later via subtyping) or even recursive.

Each field has a `row_field_repr` describing the tag's status:

- `Rpresent _` — the tag is definitely there.
- `Reither (_, _, _)` — the tag is there in some unifications but
  might be removed; this happens during type inference with
  conjunctive constraints.
- `Rabsent` — the tag has been excluded from this row.

For the linter we count both `Rpresent` and `Reither` as **present**:
in our context, both mean "the row structurally allows this tag",
which is the upper bound we care about. We're not interested in
whether a tag is mandatory — only in whether it's reachable.

`extract/tags.ml:22`:

```ocaml
let rec variant_tags (ty : type_expr) : (string * [`Present | `Absent]) list =
  let ty = Ctype.expand_head Env.empty ty in     (* peel type aliases *)
  match Types.get_desc ty with
  | Tvariant row ->
      let fields = Types.row_fields row in
      let more = Types.row_more row in
      let from_fields = List.filter_map (fun (tag, field) ->
        match Types.row_field_repr field with
        | Rpresent _ | Reither (_, _, _) -> Some (tag, `Present)
        | Rabsent -> Some (tag, `Absent)) fields in
      from_fields @ variant_tags more   (* recurse into the tail *)
  | _ -> []
```

Two subtleties:

1. We `expand_head` first because the type might be
   `type my_errors = [ \`Foo | \`Bar ]` — a synonym. Without expansion
   `get_desc` returns `Tconstr` and we'd see no fields.
2. We recurse into `row_more`. Polymorphic variant rows can be
   chained (`[ \`A | \`B ]` extended with `[ \`C ]`); the tail holds
   the rest.

`present_tags` is just `variant_tags` filtered to the
`` `Present `` ones, returning `string list`. Everywhere downstream
the linter speaks plain string lists, never `type_expr`s.

**Why payloads don't matter.** Hamlet's PPX emits service Tag rows
with an opaque payload — `Tag.r = [`Console of t Hamlet.P.t]` — so
two services with the same short name and different service types
fail to unify at the row level. The pattern in `variant_tags` is
`Rpresent _ | Reither (_, _, _)` and the wildcard `_` quietly
discards whatever payload (or no payload) the field carries. We
record *that the tag exists*, not what it carries. Set difference
on label strings is the rule's whole arithmetic, so it makes no
difference whether a tag is payload-free, carries the new opaque
service witness `t Hamlet.P.t`, or carries a user-defined payload
like `Console_error of string` — they all flow through the same
code path with no special casing.

**Why label naming doesn't matter either.** Top-level services
keep their bare label (`` `Console ``), but services declared in a
nested module get a path-qualified label using `__` as separator:
`module Outer = struct module Inner = …` produces
`` [`Outer__Inner of t Hamlet.P.t] ``. To us the label is just an
opaque string key into the set; whether it's `Console` or
`Outer__Inner__Foo` is irrelevant as long as both sides of the
`declared \ upstream` comparison see the same key — which they
always do, because both rows are typed in the same module context.

---

## Phase 9 — Handler universe (5 shapes)

The handler is the `~f` (catch family) or `~h` (provide family)
argument to the combinator. Its first parameter — or second, for
curried Layer combinators — carries the closed-row annotation
`[%hamlet.te ...]` or `[%hamlet.ts ...]` that lists every tag the
handler is supposed to cover. That's the "declared universe" we want
to extract.

Trouble is, users write handlers in five syntactically-different
ways, and after PPX expansion + typedtree elaboration they all look
different. `extract/handler.ml` enumerates the five shapes and tries
them in order; first non-empty match wins:

1. **Param-pat annotation** — `~f:(fun (x : [%hamlet.te A, B]) -> ...)`.
   The annotation lives on the first parameter's pattern; read tags
   from `param.fp_kind.pat_type`.
2. **Function-cases** — `~f:(function | ... : [%hamlet.te A, B] -> ...)`.
   The body is a `Tfunction_cases`; all cases share a scrutinee type,
   take it from the first case's `c_lhs.pat_type`.
3. **Match scrutinee** —
   `~f:(fun x -> match (x : [%hamlet.te A, B]) with ...)`. The body
   is a `Tfunction_body` wrapping a `Texp_match`; take tags from the
   first match-case's pattern type.
4. **Named handler** — `~f:handle_wide`. The handler is a
   `Texp_ident`; walk its `val_type`, take the first `Tarrow`'s
   domain (the function's parameter type), read tags from there.
5. **Apply-built handler** — `~f:(make_handler args)`. The handler
   is itself a function call; its `exp_type` is the resulting
   function type; same trick as 4.

```ocaml
let universe_tags ?(peel = 0) (handler : expression) : string list option =
  match peel_outer handler peel with
  | Some inner -> (match inner.exp_desc with
      | Texp_function (params, body) ->
          let tags = try_param_pat params in           (* shape 1 *)
          let tags = if tags<>[] then tags else try_body_tags body in  (* 2,3 *)
          if tags<>[] then Some tags else None
      | Texp_ident (_, _, vd) -> ...                   (* shape 4 *)
      | Texp_apply _ -> ...                            (* shape 5 *)
      | _ -> None)
  | None -> ...
```

If none of the five matches, return `None`; the walker treats that as
"can't tell, skip this candidate" — which is sound (no false
positive) but loses precision (potential false negative).

`~peel:1` is for **curried Layer combinators** — strip one outer
`Texp_function` layer (the implementation parameter) before applying
the five-shape logic to the inner function (where the row annotation
actually sits).

---

## Phase 10 — Upstream row (the key trick)

Now the dual problem: extract upstream's actual tag set so we can
compare with the handler's declared universe.

You'd think you could just read the upstream expression's `exp_type`,
walk to slot 1 or 2, and read the tags. That's already wrong: at the
call site, OCaml's covariant subtyping has **already widened**
upstream's row to match the handler's annotation. Reading `exp_type`
at the call site gives you the widened row — exactly the lie the
linter is supposed to expose.

The trick: when upstream is a **let-bound variable**, the variable's
`Texp_ident` carries the value's `value_description.val_type` — the
type recorded **at the binding site**, before any unification at the
call site widened it. That's the pre-widening, narrow truth.

`extract/upstream.ml:186`:

```ocaml
let rec residual ~(slot : int) (e : expression) : string list option =
  match e.exp_desc with
  | Texp_ident (_, _, vd) -> tags_at_slot vd.val_type ~slot       (* THE TRICK *)
  | Texp_apply (callee, args) -> classify_and_recurse ~slot e ~callee ~args
  | _ -> tags_at_slot e.exp_type ~slot                            (* fallback *)
```

Three branches:

- `Texp_ident` (let-bound upstream) — read `vd.val_type`. This is
  the win case: the typechecker recorded the narrow row at the
  binding site, untouched by the call-site widening.
- `Texp_apply` (inline upstream that is itself another combinator
  call) — there's no `val_type` to read because the expression
  isn't bound to a name. Recurse — see Phase 11.
- Anything else — fallback to `exp_type`. This loses precision (the
  linter under-reports) but is sound (never false positives).

`slot` is which row index to look at: 1 for catch-family (errors
`'e`), 2 for provide-family (services `'r`). Set by the caller based
on the combinator's `` `Catch `` / `` `Provide `` classification from
Phase 7.

---

## Phase 11 — Recursive residual

Phase 10's trick depends on upstream being a let-bound name. But
users often inline the upstream:

```ocaml
catch (catch eff ~f:H1) ~f:H2     (* nested *)
eff |> catch ~f:H1 |> catch ~f:H2 (* pipe form *)
```

Now the outer `catch`'s upstream is a `Texp_apply` of the inner
`catch` — there's no `Texp_ident`, no `val_type`. The `exp_type` of
the inner is already widened to match the outer's annotation. We're
stuck unless we recurse.

The idea: ask "what row would the inner combinator actually produce
on the slot the outer cares about?" Call this the **residual** of
the inner. The residual is not necessarily the same as the inner's
annotation; it depends on what the inner's handler does to the row.

Some slots are easy. A `provide` doesn't change the errors row, and
a `catch` doesn't change the services row. We call those
**pass-through** slots — the residual is just what came in, so we
recurse on the inner's upstream.

The other slots are **touched** by the inner combinator. There the
inner's handler shape determines what comes out. Sometimes we can
compute the residual exactly (Phase 12); when we can't, we fall back
to the widened `exp_type`.

| Inner combinator                 | Slot 1 (errors) | Slot 2 (services) |
|----------------------------------|-----------------|-------------------|
| `catch`                          | touched ¹       | pass-through      |
| `map_error`                      | touched ²       | pass-through      |
| `provide`, `Layer.provide_to_*`  | pass-through    | touched ¹         |

¹ Exact residual when the handler matches a recognised shape (Phase
12); otherwise fallback to widened `exp_type`.
² No recognised handler shape — `map_error`'s handler returns a
fresh tag value, not `fail`, so the residual is always the
widened fallback.

`extract/upstream.ml:232`:

```ocaml
and residual_through ~slot ~kind ~peel args (outer_e : expression) =
  let pass_through () = match upstream with
    | Some up -> residual ~slot up                 (* RECURSE on inner upstream *)
    | None -> tags_at_slot outer_e.exp_type ~slot in
  let touched () = ... in                          (* delegate to Phase 12 *)
  match (kind, slot) with
  | `Catch, 1 -> touched ()
  | `Catch, _ -> pass_through ()
  | `Provide, 2 -> touched ()
  | `Provide, _ -> pass_through ()
```

Recursion terminates because every step either:

- hits a `Texp_ident` (read val_type, done);
- hits a non-combinator expression (read exp_type, done);
- consumes one combinator layer and recurses on its strictly-smaller
  positional argument.

---

## Phase 12 — Pure-propagate / give / need

When the recursion hits a touched slot, we need to compute what the
inner combinator's handler actually does to the row. In general this
is undecidable — the handler is arbitrary OCaml code. But two
specific shapes cover the common cases that PPX-generated code
produces, plus user code that mirrors them.

**catch with pure-propagate handler.** Every match arm has the shape
`` match x with `Foo as e -> fail e | `Bar as e -> fail e | ... ``.
Each arm binds an alias on its pattern (typically a polymorphic-
variant tag, as PPX emits) and immediately re-emits that alias via
`Hamlet.Combinators.fail`. Semantically a row **no-op**: the
handler emits exactly what it received. The PPX-generated
`[%hamlet.propagate_e]` expansion produces this shape. When the
catch handler is pure-propagate, the residual on slot 1 is just
the inner upstream's residual on slot 1. Recurse.

`extract/propagate.ml:237` shows the per-arm check:

```ocaml
let arm_is_pure_propagate (Arm (lhs, guard, rhs)) =
  if guard <> None then false               (* guarded arms never qualify *)
  else
    match (alias_var lhs, rhs.exp_desc) with
    | Some var, Texp_apply (callee, [(Nolabel, Arg arg)]) ->
        let path_is_fail = match callee.exp_desc with
          | Texp_ident (path, _, _) -> is_fail_callee path
          | _ -> false in
        path_is_fail && (is_ident_var arg var || is_expose_of_var arg var)
    | _ -> false
```

The arm must (a) be unguarded, (b) bind the matched value to a name
(`as e`), (c) call `Hamlet.Combinators.fail` (recognised by
canonical path) on exactly that name (or the cross-CU `expose`
wrapping of it). Any deviation → `Catch_other` → fallback.

**provide with give/need handler.** Every match arm is one of:

- `<X>.Tag.give alias impl` — the handler **discharges** this
  service by handing in an implementation. The matched tag
  disappears from the residual.
- `Hamlet.Dispatch.need alias` — the handler **re-emits** the same
  need; this arm contributes nothing to the residual (it's a
  pass-through for that tag).

If every arm is one of these two (mixed give+need is the common
idiom — provide some services, propagate the rest), the residual
on slot 2 is `upstream_r ∖ <union of give-tags>`:

```
Provide_residual <give-tags>
  → residual_r = upstream_r ∖ <give-tags>
```

Anything else — handler that does custom dispatch, returns a
different tag, calls something other than `fail`/`give`/`need` —
collapses to `Catch_other` / `Provide_other` and the recursion falls
back to the widened `exp_type`.

This conservative fallback preserves the linter's invariant: **false
negatives only, never false positives**. The fallback row
over-approximates upstream's actual row, which under-approximates
the diff `declared \ upstream`, which under-approximates findings.

---

## Phase 13 — Pipe form unstaging

You'd expect `eff |> catch ~f:H` to compile to the same typedtree
as `catch eff ~f:H`. It doesn't. OCaml's `|>` is `let (|>) x f = f x`,
but at the typedtree level when `catch` is partially applied, you
get a **staged** apply: two `Texp_apply` nodes for one logical call.

```
Texp_apply (
  Texp_apply (catch_ident, [(~f, Arg H); (Nolabel, Omitted)]),  (* inner: partial *)
  [(Nolabel, Arg eff)])                                           (* outer: feeds it *)
```

The inner is a partial application of `catch ~f:H` with the
positional `eff` slot marked `Omitted` (placeholder for an argument
not yet supplied). The outer wraps that partial and provides the
missing positional.

If we don't deal with this, the walker only dispatches to
`process_call` when the callee is a direct `Texp_ident`
(`walker.ml:124`); a staged `Texp_apply` callee falls through to a
silent skip — the classifier is never even invoked. The recursive
residual is symmetrical: a non-ident callee falls back to the widened
`exp_type` (`upstream.ml:200`). Either way, pipe form would silently
escape detection.

`extract/upstream.ml:99` is the unstaging function:

```ocaml
let unstage_apply (e : Typedtree.expression) =
  match e.exp_desc with
  | Texp_apply (outer_callee, outer_args) -> (
      match outer_callee.exp_desc with
      | Texp_apply (inner_callee, inner_args) -> (
          match inner_callee.exp_desc with
          | Texp_ident _ ->
              (* splice outer positional Args into inner Omitted positional slots *)
              ...
              Some (inner_callee, spliced)
          | _ -> None)
      | _ -> None)
  | _ -> None
```

It recognises the staged shape: outer wraps inner; inner's callee is
a real `Texp_ident`; inner has `Omitted` slots that we can fill from
outer's positional args. We splice outer's positional `Arg`s into
inner's `Omitted` slots, producing a canonical full-arg list — as
if the user had written the direct `catch eff ~f:H` form.

The walker (`walker.ml:139`) and the recursive residual
(`upstream.ml:215`) both call `unstage_apply` before classifying, so
pipe and nested forms behave identically downstream. The reported
location is the inner partial's location — i.e. the actual `catch`
keyword in the source — not the start of the chain.

---

## Phase 14 — Report

`analyzer/report.ml:16` formats one finding into a multi-line string.
The format mirrors the upstream PoC's output so snapshot tests
carrying over from the PoC don't drift.

```
File "test/cases/widening_cases.ml", line 25, characters 11-11:
  hamlet-lint WARNING: catch handler declares [%hamlet.te ...] tags not present in upstream.
    declared  : [Console; Database]
    upstream  : [Console]
    extra tag not emitted : [Database]
```

Line 1 is the standard `File "...", line N, characters X-Y:` format
that editors and CI parsers know how to navigate to a clickable
location. Subsequent lines spell out: which combinator family fired,
what the handler claimed, what upstream actually has, and which tags
are extra. `extra` is the difference computed by Phase 5.

The phrase "extra tag(s) not emitted" pluralises based on
`List.length f.extra` — small detail but it's the kind of thing
that would otherwise feel rough on real output.

---

## Phase 15 — Config

The CLI alone is enough to run the linter, but it's annoying to type
the same `--exclude` flags every time, and CI / local invocations
should agree on what to lint. So the project supports an optional
config file at `<repo-root>/.hamlet-lint.sexp`:

```sexp
(targets _build/default/lib _build/default/bin)
(exclude _build/default/test)
(mode warn)
```

- `targets` (required) — paths the linter should walk for `.cmt`
  files. At least one entry.
- `exclude` (optional) — paths to skip even if they're inside a
  target.
- `mode` (optional, default `fail`) — `fail` makes the analyzer exit
  1 on findings, `warn` makes it always exit 0 (useful for early
  adoption, where you want findings as informational warnings without
  breaking CI).

Discovery: `Config.find` walks up from `cwd` looking for
`.hamlet-lint.sexp`. Relative paths in the config are resolved
against the **config file's directory** (not cwd), so invoking
`hamlet-lint` from a subdirectory still points at the right build
outputs.

`config/config.ml` is ~150 LOC of plain s-expression parsing with
explicit error messages: an unknown top-level form, a missing
`targets`, a `mode` other than `fail`/`warn` all surface as a typed
error message rather than a silent skip.

---

## Phase 16 — CLI drivers

**Extract** (`extract/main.ml`) uses the stdlib `Arg` module:

```sh
hamlet-lint-extract [--canonical] [--exclude PATH ...] [--config FILE] [DIRS|FILES]
```

- Positional args are paths; if a path is a directory it's walked
  recursively for `.cmt` files.
- `--exclude PATH` (repeatable) drops cmt files whose absolute path
  starts with `PATH`. The check is path-segment-aware: excluding
  `/a/foo` does NOT also exclude `/a/foobar` (a real bug surfaced
  by an early codex review).
- `--config FILE` loads an explicit config; without it, falls back
  to upward discovery (Phase 15).
- `--canonical` sorts the output by `(file, line, col)`. Used by
  snapshot tests so output is deterministic.

Inputs are CLI args ∪ config `targets`, minus excluded paths. Then
it walks them all, prints the header, then prints each candidate.
Findings are the analyzer's job, so extract exits 0 unless something
went wrong (missing path, corrupt cmt → exit 2 with a stderr message
prefixed `hamlet-lint-extract:`).

**Analyze** (`analyzer/main.ml`) uses cmdliner:

```sh
hamlet-lint [-i FILE | --input FILE] [-w | --warn-only]
```

- Reads ND-JSON from stdin (default) or `--input FILE`.
- Validates the header is present and has a matching `schema_version`.
  If not, exit 2 with a clear message.
- Applies the rule, prints findings.
- Exit code: 0 (clean), 1 (findings), 2 (malformed input).
  `--warn-only` (and config `mode warn`) override 1 → 0.

---

## Phase 17 — Compat firewall

`compiler-libs.common` is the OCaml compiler exposed as a library.
Its API — types like `Types.row_field`, constructors like
`Tparam_pat`, `Tfunction_cases`, fields like `cmt_annots` — is
**not** stable across OCaml minor versions. A 5.4 → 5.5 transition
will break some of them.

Since the extractor links `compiler-libs`, the extractor is
OCaml-version-coupled. We have to recompile the extractor (and
probably patch source) for every OCaml minor we want to support. The
release model packages this as `hamlet-lint.<hamlet>~<ocaml>` — one
package per `(hamlet, ocaml-patch)` pair on opam-repository.

To make patching tractable, every API access that might drift goes
through a single file: `extract/compat.cppo.ml`. Today it just
enforces the supported window:

```ocaml
#if OCAML_VERSION < (5, 4, 1) || OCAML_VERSION >= (5, 5, 0)
#error "hamlet-lint currently supports only OCaml 5.4.1"
#endif
```

A dune rule preprocesses it through `cppo` with the build's actual
OCaml version (`extract/dune:32`):

```
(rule (targets compat.ml) (deps compat.cppo.ml)
      (action (run %{bin:cppo} -V OCAML:%{ocaml_version} %{deps} -o %{targets})))
```

When 5.5.0 arrives and breaks something, the workflow is: widen the
`#error` window, add `#if OCAML_VERSION = (5,5,0) ... #else ... #endif`
branches around the drifted bodies, re-run tests against both
patches. See `docs/CONTRIBUTING.md`.

---

## Phase 18 — Tests

Two test executables, both alcotest-based. `test/dune` declares them;
`dune runtest --force` runs both.

**Unit tests** (`test/test_rule.ml`) build schema records by hand —
no extractor, no fixtures, no compiler-libs — and run them through
`Rule.check` / `Rule.analyze`:

```ocaml
let check_extra_when_declared_wider () =
  let c = mk_candidate ~declared:["A";"B";"C"] ~upstream:["A"] () in
  match Rule.check c with
  | None -> Alcotest.fail "expected a finding"
  | Some f -> Alcotest.(check (list string)) "extra" ["B";"C"] f.extra
```

These are the fast tests; they pin the rule's set-difference logic
and a couple of classifier predicates (`Classify.path_root_is_hamlet`
in particular, with a list of lookalike names to confirm rejections).

**E2E tests** (`test/test_e2e.ml`) compile fixture libraries
(`test/cases/*.ml`) into `.cmt` files via dune, then run the actual
`extract | analyze` pipeline as subprocesses, then assert on the
output:

```ocaml
let cases = [
  { fixture = "Widening_cases"; expected_exit = 1; expected_lines = [25;37;64] };
  { fixture = "Edge_cases";     expected_exit = 1; expected_lines = [46;69;78;90;103] };
  { fixture = "Layer_cases";    expected_exit = 1; expected_lines = [34;59;94;160;183] };
  { fixture = "Cross_cu_cases"; expected_exit = 1; expected_lines = [40;71] };
  { fixture = "Chained_cases";  expected_exit = 1; expected_lines = [43;55;75;112;136;177] };
]
```

Each entry pins which lines must show up flagged in the analyzer's
output for that fixture. New regression? Add a fixture, add its line
numbers, `make test`.

A second batch of tests covers the contracts at the boundaries:
missing header → exit 2, malformed candidate → exit 2, garbage JSON
→ exit 2; missing path on extract or analyzer → exit 2 + the
controlled `hamlet-lint-extract:` stderr prefix (essential because
an OCaml uncaught exception ALSO exits 2 by convention, so the
exit code alone can't distinguish a controlled `die_user_error` from
an uncaught crash — the stderr prefix is what tells them apart).

---

## Phase 19 — Build system

`dune-project` declares one package, `hamlet-lint`, depending on
`hamlet`, `compiler-libs.common`, `cppo` (build-only), `yojson`,
`cmdliner`, `parsexp`, `sexplib0`, `alcotest` (test-only). OCaml is
pinned to `>= 5.4.1, < 5.4.2` for development; release packaging
substitutes a per-pair pin.

The source is split into 5 dune libraries + 2 executables:

| Lib                            | Public name             | Deps                                                 |
|--------------------------------|-------------------------|------------------------------------------------------|
| `hamlet_lint_schema`           | `hamlet-lint.schema`    | `yojson`                                             |
| `hamlet_lint_config`           | `hamlet-lint.config`    | `parsexp`, `sexplib0`, `unix`                        |
| `hamlet_lint_extract`          | `hamlet-lint.extract`   | `compiler-libs.common`, `yojson`, `unix`, schema, config |
| `hamlet_lint_analyzer`         | `hamlet-lint.analyzer`  | schema                                               |
| `hamlet_lint_fixtures` (test)  | (priv)                  | `hamlet`, `hamlet_test_services` (with `ppx_hamlet`) |

Why so many small libraries instead of one? Two reasons:

1. **Linkage isolation.** `hamlet_lint_analyzer` doesn't depend on
   `compiler-libs` — that means the analyzer binary stays small and
   OCaml-version-agnostic. The two-binary architecture is enforced
   by the dependency graph, not just by convention.
2. **Test linkage.** Unit tests can pull in just `hamlet_lint_schema`
   + `hamlet_lint_extract` to test individual modules (e.g.
   `Classify.path_root_is_hamlet`) without rebuilding the whole
   world.

The two executables are `hamlet-lint-extract` (in `extract/`) and
`hamlet-lint` (in `analyzer/`), each a thin driver around its
respective library.

---

## Phase 20 — Make targets

The `Makefile` is a thin convenience wrapper around `dune`. Common
moves:

```sh
make build                            # dune build
make test                             # full alcotest suites + e2e
make fmt                              # dune fmt check (CI-style, fails on diff)
make fmt-fix                          # auto-format the whole project
make all                              # build + test + fmt + doc + opam lint
make list                             # list available fixture names
make run FIXTURE=widening_cases       # extract|analyze on one fixture, exit 1 if findings
make warn FIXTURE=chained_cases       # same but --warn-only (exit 0)
make ndjson FIXTURE=widening_cases    # show the canonical ND-JSON the extractor emits
make debug FIXTURE=...                # extract|analyze with HAMLET_LINT_DEBUG=1
```

`PROMOTE=1` on any target (e.g. `make fmt PROMOTE=1`) runs
`dune promote` after, which writes back any expected-vs-actual diffs
from snapshot tests or formatter rules.

The fixture-scoped targets (`run`/`warn`/`ndjson`/`debug`) require
`FIXTURE=<name>`; without it, they print the available list and
fail with a hint.

---

## Phase 21 — Limitations

`docs/LIMITATIONS.md` enumerates 8 known gaps — cases the linter
**doesn't** catch by design. Two you'll see most:

**§1 — Inline upstream from non-monitored ops.** Phase 11's
recursion only handles inner combinators that are themselves
monitored (catch / provide / their Layer counterparts). When the
inline upstream is built from anything else — `let*`/`bind`,
`try_catch`, `pure`, `Layer.make` — there's no recognised inner
combinator to recurse through, so we fall back to the widened
`exp_type` and miss the bug. Workaround: let-bind upstream first.

**§6 — Aliased Hamlet primitives.** The pure-propagate / give /
need detector recognises `Hamlet.Combinators.fail`,
`Hamlet.Dispatch.need`, `<X>.Tag.give` only by canonical path. If
the user does `let open Hamlet.Combinators in ... fail e ...`,
the path is just `fail`; we don't follow that. Works for the
canonical PPX-generated form; user-written aliased forms are out of
scope (would require expensive `val_type` chasing for too little
real-world gain).

The remaining seven (handler shapes we don't pattern-match,
combinators outside the twelve monitored, OCaml-version coupling,
computed combinator references, locally-aliased combinator,
multi-callback combinators inspected only on their primary probe,
let-bound partial application) follow similar trade-offs: each
could be supported in principle, each pays a precision-vs-
complexity cost the project chose not to take.

The invariant across every fallback: **false negatives only, never
false positives**. Every fallback over-approximates upstream's row,
which under-approximates the diff `declared \ upstream`, which
under-approximates findings. So a clean run never lies about the
absence of bugs — it just may not find every present bug.

---

## Phase 22 — Hands-on exercises

Concrete things to do, in increasing depth.

**A. See it run end-to-end.**

```sh
make build
make run FIXTURE=widening_cases     # exit 1, three findings
make ndjson FIXTURE=widening_cases  # see the wire records the extractor emits
```

Look at the ND-JSON output and cross-reference each candidate
against the source line in `test/cases/widening_cases.ml`. You
should be able to point at the `declared` and `upstream` values and
explain where in the source they came from.

**B. Add a BAD fixture.**

1. Append to `test/cases/edge_cases.ml` a function with a deliberate
   widening (handler declares more tags than upstream emits).
2. Note the line number of the `catch`/`provide` keyword.
3. Add it to `expected_lines` for `Edge_cases` in
   `test/test_e2e.ml:73`.
4. `make test`. The new line should appear in the analyzer's output
   and match the expectation.

**C. Trace a finding from cmt to report.**

```sh
make build
hamlet-lint-extract --canonical \
  _build/default/test/cases/.hamlet_lint_fixtures.objs/byte/hamlet_lint_fixtures__Widening_cases.cmt
```

Read each candidate's `declared` vs `upstream` lists and line them
up against the source. Pipe through `hamlet-lint` to see the rule
applied.

**D. Break the rule, watch tests fail.**

In `analyzer/rule.ml:29`, change `if extra = []` to `if false`. Run
`make test`. Every GOOD fixture starts producing findings (the
linter is now reporting on subsets too). Revert. This drives home
that the entire rule lives in that one line and every test gates on
it.

**E. Read in dependency order.**

`tags.ml` → `classify.ml` → `propagate.ml` → `handler.ml` →
`upstream.ml` → `walker.ml` → `extract/main.ml` → `schema.ml` →
`analyzer/rule.ml` → `analyzer/report.ml` → `analyzer/main.ml` →
`config.ml`.

Bottom-up. ~2K LOC total. Half a day to walk through carefully
with this guide open as a map.

---

**Compression test.** If you can explain in one sentence what
hamlet-lint does — *"the walker emits `(declared, upstream)` per
call site, the analyzer subtracts, non-empty diff is a finding,
every other module is plumbing"* — you've absorbed it.
