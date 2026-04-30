(** Extract the universe of tags a handler declares it can cover.

    Five recognized handler shapes (tried in order, first match wins):

    1. [Texp_function] with a first parameter pattern that already carries the
    closed row (annotated via [fun (x : [%hamlet.te A, B]) -> ...]). The PPX has
    expanded the attribute into a [pat_type] that is a [Tvariant] with the named
    tags as [Rpresent].

    2. [Texp_function] whose body is a [Tfunction_cases] (anonymous [function]).
    The cases share a scrutinee type — read tags from the first case's
    [c_lhs.pat_type].

    3. [Texp_function] whose body is a [Tfunction_body] wrapping a [Texp_match].
    Read tags from the first match case's [c_lhs.pat_type] (covers
    [fun x -> match (x : [%hamlet.te ...]) with ...] and whole-function
    annotations).

    4. [Texp_ident] — a named handler reference like [~f:handle_wide] or
    [~f:Module.handle]. Walk [val_type], take the first [Tarrow]'s domain, read
    tags from there.

    5. [Texp_apply] — a handler built at the call site by a helper that takes
    some args and returns a function ([~f:(make_handler args)]). Same trick as 4
    but on the apply's [exp_type].

    {1 Curried handlers}

    The Layer combinators ([Layer.provide_to_effect], [Layer.provide_to_layer],
    [Layer.provide_merge_to_layer], [Combinators.provide_scope]) take a curried
    handler; the row annotation is on the SECOND parameter, not the first.
    {!universe_tags} accepts [~peel] to consume that many outer parameters
    before applying the five-shape logic to the remainder. [~peel:0] is the
    original behaviour.

    {1 Cause.t-wrapped handlers}

    [catch_cause] and [catch_cause_filter] wrap the handler parameter in
    [Hamlet.Cause.t]: [fun (c : ([%hamlet.te ...]) Hamlet.Cause.t) -> ...]. When
    [~wraps_in_cause:true], the pat type (or arrow domain) is unwrapped one
    [Tconstr] layer before being passed to {!Tags.present_tags}. *)

open Typedtree

(** Strip one outer [Tconstr] layer when it is a single-argument constructor
    rooted in the Hamlet library (typically [Hamlet.Cause.t]). If the type does
    not match that shape, return it unchanged.

    This lets the tag extractor look through
    [(c : ([%hamlet.te Console, Database]) Hamlet.Cause.t)] and recover the row
    [Console | Database] that sits inside. *)
let strip_cause_wrapper (ty : Types.type_expr) : Types.type_expr =
  let ty = Ctype.expand_head Env.empty ty in
  match Types.get_desc ty with
  | Tconstr (path, [ row ], _) when Classify.path_root_is_hamlet path -> row
  | _ -> ty

(** Drop into a pattern's type, optionally stripping a [Cause.t] wrapper. *)
let tags_from_pat_type ~wraps_in_cause pat_type =
  let ty = if wraps_in_cause then strip_cause_wrapper pat_type else pat_type in
  Tags.present_tags ty

(** All cases of a [function | ... | ...] share a scrutinee type. Take the first
    case's pattern type. *)
let tags_from_cases ~wraps_in_cause : value case list -> string list = function
  | c :: _ -> tags_from_pat_type ~wraps_in_cause c.c_lhs.pat_type
  | [] -> []

(** Try shape 1: first param pattern. Handles both plain and optional-default
    parameters. *)
let try_param_pat ~wraps_in_cause (params : function_param list) : string list =
  match params with
  | param :: _ ->
      let pat =
        match param.fp_kind with
        | Tparam_pat p -> p
        | Tparam_optional_default (p, _) -> p
      in
      tags_from_pat_type ~wraps_in_cause pat.pat_type
  | [] -> []

(** Try shapes 2 and 3: function body. *)
let try_body_tags ~wraps_in_cause : function_body -> string list = function
  | Tfunction_cases { cases; _ } -> tags_from_cases ~wraps_in_cause cases
  | Tfunction_body body_exp -> (
      match body_exp.exp_desc with
      | Texp_match (_, cases, _, _) -> (
          match cases with
          | (c : computation case) :: _ ->
              tags_from_pat_type ~wraps_in_cause c.c_lhs.pat_type
          | [] -> [])
      | _ -> [])

(** Shapes 4 and 5: a handler that is itself a value reference ([Texp_ident]) or
    an application ([Texp_apply]). Strip [n] outer arrows to skip
    curried-handler leading parameters, then take the next arrow's domain. When
    [~wraps_in_cause] is true the domain is unwrapped before tag extraction. *)
let tags_from_arrow_domain ?(strip = 0) ~wraps_in_cause (ty : Types.type_expr) :
    string list =
  let rec peel n ty =
    if n = 0 then Some ty
    else
      let ty = Ctype.expand_head Env.empty ty in
      match Types.get_desc ty with
      | Tarrow (_, _, codom, _) -> peel (n - 1) codom
      | _ -> None
  in
  match peel strip ty with
  | None -> []
  | Some ty -> (
      let ty = Ctype.expand_head Env.empty ty in
      match Types.get_desc ty with
      | Tarrow (_, dom, _, _) ->
          let dom = if wraps_in_cause then strip_cause_wrapper dom else dom in
          Tags.present_tags dom
      | _ -> [])

(** Strip [n] outer [Texp_function] layers from a handler expression. Each
    stripped layer must consume exactly one parameter and have a function body
    (not function-cases) — anything else returns [None] (we cannot tell where
    the row annotation actually sits). *)
let rec peel_outer (handler : expression) (n : int) : expression option =
  if n = 0 then Some handler
  else
    match handler.exp_desc with
    | Texp_function ([ _outer ], Tfunction_body inner) ->
        peel_outer inner (n - 1)
    | _ -> None

(** Top-level: extract the handler's declared tag universe, returning [None]
    when no recognized shape produces a non-empty tag list. The caller treats
    [None] as "cannot tell" and skips the call. [~peel] is the number of outer
    [Texp_function] layers to strip first (used for curried handlers in
    [Layer.provide_to_*] and [Combinators.provide_scope]). [~wraps_in_cause]
    indicates the handler parameter is wrapped in [Hamlet.Cause.t] and must be
    unwrapped one [Tconstr] level before tag extraction. *)
let universe_tags ?(peel = 0) ?(wraps_in_cause = false) (handler : expression) :
    string list option =
  match peel_outer handler peel with
  | None ->
      (* Could not strip the requested layers — fall back to reading the
         handler's exp_type with [~strip:peel] for the named/apply shapes. *)
      let ty =
        match handler.exp_desc with
        | Texp_ident (_, _, vd) -> vd.val_type
        | _ -> handler.exp_type
      in
      let tags = tags_from_arrow_domain ~strip:peel ~wraps_in_cause ty in
      if tags <> [] then Some tags else None
  | Some inner -> (
      match inner.exp_desc with
      | Texp_function (params, body) ->
          let tags = try_param_pat ~wraps_in_cause params in
          let tags =
            if tags <> [] then tags else try_body_tags ~wraps_in_cause body
          in
          if tags <> [] then Some tags else None
      | Texp_ident (_, _, vd) ->
          let tags = tags_from_arrow_domain ~wraps_in_cause vd.val_type in
          if tags <> [] then Some tags else None
      | Texp_apply _ ->
          let tags = tags_from_arrow_domain ~wraps_in_cause inner.exp_type in
          if tags <> [] then Some tags else None
      | _ -> None)
