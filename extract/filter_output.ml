(** Infer the upper bound of tags that a [catch_filter] / [catch_cause_filter]
    [~filter] callback can return inside [Some _].

    The output universe ['match_] of the filter is independent of upstream's
    error row ['e] when the filter is not the identity. The handler's [~f]
    parameter is annotated with a closed row that should match the tags filter
    actually produces. If declared is wider than the inferred upper bound, the
    extra tags are dead-code arms — the same retroactive-widening pattern, on a
    different row.

    {1 Strategy: walk return positions, not syntactic [Some _] nodes}

    A naïve sweep of every [Texp_construct (Some, [arg])] under the body would
    be unsound: a branch can return an opaque option value built elsewhere
    ([Some] inside a [let], an external [option]-producing helper) without ever
    visibly constructing [Some _] at the function's return position. The
    actually-emitted tag set is then a superset of what the sweep sees, and
    [declared \ inferred] would flag tags that filter genuinely emits — a false
    positive.

    Instead we walk control-flow {b leaves} of the body — the expressions that
    are actual return values. At each leaf we require either a literal [None], a
    literal [Some <variant>] / [Some <bound_var>], or we abort. Aborting means
    the output universe is unknown; the caller emits no candidate
    (false-negative-only fallback, matches the project's safety invariant). *)

open Typedtree

(** True when [cd] is the [Some] data constructor of [option]. *)
let is_some_constructor (cd : Data_types.constructor_description) : bool =
  if cd.cstr_name <> "Some" then false
  else
    match Types.get_desc cd.cstr_res with
    | Tconstr (path, _, _) -> Path.last path = "option"
    | _ -> false

(** True when [cd] is the [None] data constructor of [option]. *)
let is_none_constructor (cd : Data_types.constructor_description) : bool =
  if cd.cstr_name <> "None" then false
  else
    match Types.get_desc cd.cstr_res with
    | Tconstr (path, _, _) -> Path.last path = "option"
    | _ -> false

(** Read the structural tag from a [Some _]'s argument:

    - [Texp_variant (label, _)] — inline polymorphic-variant constructor
      [\`label _]: the AST records the literal tag name. This is the only shape
      we can read SOUNDLY: [exp_type] is post-unification, so an annotation on
      [~f]'s parameter widens it; the literal label is annotation-independent.
    - [Texp_ident (_, _, vd)] — a name bound earlier (e.g. by a pattern):
      [vd.val_type] is the declaration-time type, also pre-widening.

    For every other shape (function call, complex expression building a variant
    programmatically) we return [None] — caller treats as "unknown output",
    which collapses the inference to [None] (no finding emitted — safe under the
    no-false-positives invariant). *)
let some_arg_tags (arg : expression) : string list option =
  match arg.exp_desc with
  | Texp_variant (label, _) -> Some [ label ]
  | Texp_ident (_, _, vd) -> (
      match Tags.present_tags vd.val_type with [] -> None | tags -> Some tags)
  | _ -> None

(** Combine two optional tag sets: both must be [Some] for the union to be
    [Some]; any [None] short-circuits to [None] (one branch is opaque, so the
    overall set is unknown). Order-preserving, deduplicating. *)
let combine (a : string list option) (b : string list option) :
    string list option =
  match (a, b) with
  | Some la, Some lb ->
      let merged =
        List.fold_left
          (fun acc t -> if List.mem t acc then acc else acc @ [ t ])
          la lb
      in
      Some merged
  | _ -> None

(** Walk a single return position — the expression at a control-flow leaf of the
    filter's body. A return position is what the function evaluates to on one
    path through the body. We recognise:

    - [None] — contributes nothing ([Some []]).
    - [Some <variant>] / [Some <ident>] — contributes the structural tag(s).
    - [Texp_match] / [Texp_function]'s [Tfunction_cases] — recurse on each
      case's RHS.
    - [Texp_let] / [Texp_letmodule] / [Texp_letexception] — recurse on body.
    - [Texp_ifthenelse] — recurse on both branches.
    - [Texp_sequence (_, e2)] — recurse on [e2] (sequence's value is its second
      expression).
    - [Texp_try (body, cases)] — recurse on body and each handler.

    Any other shape (function call, identifier of [option] type that isn't
    [None], programmatic option construction, etc.) returns [None] — inference
    aborts. *)
let rec walk_return (e : expression) : string list option =
  match e.exp_desc with
  | Texp_construct (_, cd, []) when is_none_constructor cd -> Some []
  | Texp_construct (_, cd, [ arg ]) when is_some_constructor cd ->
      some_arg_tags arg
  | Texp_match (_, comp_cases, eff_cases, _) ->
      combine (walk_match_cases comp_cases) (walk_match_cases eff_cases)
  | Texp_function (_, Tfunction_cases { cases; _ }) -> walk_match_cases cases
  | Texp_function (_, Tfunction_body body) -> walk_return body
  | Texp_let (_, _, body) -> walk_return body
  | Texp_letmodule (_, _, _, _, body) -> walk_return body
  | Texp_letexception (_, body) -> walk_return body
  | Texp_ifthenelse (_, a, Some b) -> combine (walk_return a) (walk_return b)
  | Texp_sequence (_, e2) -> walk_return e2
  | Texp_try (body, exn_cases, eff_cases) ->
      let acc = walk_return body in
      let acc = combine acc (walk_match_cases exn_cases) in
      combine acc (walk_match_cases eff_cases)
  | _ -> None

(** Reduce a list of cases (any [k general_pattern case]) to the union of their
    RHS return tag sets. If any case is opaque, the union is opaque. *)
and walk_match_cases : type k. k case list -> string list option =
 fun cases ->
  List.fold_left
    (fun acc c -> combine acc (walk_return c.c_rhs))
    (Some []) cases

(** Top-level: returns the inferred upper-bound tag set for the filter's output,
    or [None] when any return path is opaque. *)
let infer_output_tags (filter : expression) : string list option =
  walk_return filter
