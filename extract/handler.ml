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
    but on the apply's [exp_type]. *)

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
    an application ([Texp_apply]) — walk the arrow-typed value, take the first
    arrow's domain. *)
let tags_from_arrow_domain (ty : Types.type_expr) : string list =
  let ty = Ctype.expand_head Env.empty ty in
  match Types.get_desc ty with
  | Tarrow (_, dom, _, _) -> Tags.present_tags dom
  | _ -> []

(** Top-level: extract the handler's declared tag universe, returning [None]
    when no recognized shape produces a non-empty tag list. The caller treats
    [None] as "cannot tell" and skips the call. *)
let universe_tags (handler : expression) : string list option =
  match handler.exp_desc with
  | Texp_function (params, body) ->
      let tags = try_param_pat params in
      let tags = if tags <> [] then tags else try_body_tags body in
      if tags <> [] then Some tags else None
  | Texp_ident (_, _, vd) ->
      let tags = tags_from_arrow_domain vd.val_type in
      if tags <> [] then Some tags else None
  | Texp_apply _ ->
      let tags = tags_from_arrow_domain handler.exp_type in
      if tags <> [] then Some tags else None
  | _ -> None
