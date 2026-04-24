(** Extract the universe of tags an [~f] / [~h] handler declares it can cover.

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
    [Layer.provide_merge_to_layer]) take a curried handler
    [svc -> r_in -> dispatch]; the row annotation is on the SECOND parameter,
    not the first. {!universe_tags} accepts [~peel] to consume that many outer
    parameters before applying the five-shape logic to the remainder. [~peel:0]
    is the original behaviour. *)

open Typedtree

(** Drop into a pattern's type, no further unwrapping. *)
let tags_from_pat_type pat_type = Tags.present_tags pat_type

(** All cases of a [function | ... | ...] share a scrutinee type. Take the first
    case's pattern type. *)
let tags_from_cases : value case list -> string list = function
  | c :: _ -> tags_from_pat_type c.c_lhs.pat_type
  | [] -> []

(** Try shape 1: first param pattern. Handles both plain and optional-default
    parameters. *)
let try_param_pat (params : function_param list) : string list =
  match params with
  | param :: _ ->
      let pat =
        match param.fp_kind with
        | Tparam_pat p -> p
        | Tparam_optional_default (p, _) -> p
      in
      tags_from_pat_type pat.pat_type
  | [] -> []

(** Try shapes 2 and 3: function body. *)
let try_body_tags : function_body -> string list = function
  | Tfunction_cases { cases; _ } -> tags_from_cases cases
  | Tfunction_body body_exp -> (
      match body_exp.exp_desc with
      | Texp_match (_, cases, _, _) -> (
          match cases with
          | (c : computation case) :: _ -> tags_from_pat_type c.c_lhs.pat_type
          | [] -> [])
      | _ -> [])

(** Shapes 4 and 5: a handler that is itself a value reference ([Texp_ident]) or
    an application ([Texp_apply]). Strip [n] outer arrows to skip
    curried-handler leading parameters, then take the next arrow's domain. *)
let tags_from_arrow_domain ?(strip = 0) (ty : Types.type_expr) : string list =
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
      | Tarrow (_, dom, _, _) -> Tags.present_tags dom
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
    [Layer.provide_to_*]). *)
let universe_tags ?(peel = 0) (handler : expression) : string list option =
  match peel_outer handler peel with
  | None ->
      (* Could not strip the requested layers — fall back to reading the
         handler's exp_type with [~strip:peel] for the named/apply shapes. *)
      let ty =
        match handler.exp_desc with
        | Texp_ident (_, _, vd) -> vd.val_type
        | _ -> handler.exp_type
      in
      let tags = tags_from_arrow_domain ~strip:peel ty in
      if tags <> [] then Some tags else None
  | Some inner -> (
      match inner.exp_desc with
      | Texp_function (params, body) ->
          let tags = try_param_pat params in
          let tags = if tags <> [] then tags else try_body_tags body in
          if tags <> [] then Some tags else None
      | Texp_ident (_, _, vd) ->
          let tags = tags_from_arrow_domain vd.val_type in
          if tags <> [] then Some tags else None
      | Texp_apply _ ->
          let tags = tags_from_arrow_domain inner.exp_type in
          if tags <> [] then Some tags else None
      | _ -> None)
