(** Compiler-libs compatibility firewall.

    Every access to [Types.*] / [Typedtree.*] shapes that can drift across OCaml
    minors lives here. When a 5.x → 5.(x+1) transition breaks something, patch
    this single file: add a [#if OCAML_VERSION >= (5, 5, 0)] branch around the
    affected body.

    This file is preprocessed by [cppo] (see [extract/dune]) with
    [-V OCAML:%{ocaml_version}], producing [compat.ml] in the build dir. v0.1
    supports OCaml 5.4.1 exactly; the guard below is the enforcement.

    API surface intentionally tiny:
    - [row_lower_bound]: given a [type_expr], if it resolves to a [Tvariant]
      return its [Rpresent] tag names (the row's definitely-present lower
      bound).
    - [effect_type_row_lbs]: given a [type_expr] that should be
      [('a, 'e, 'r) Hamlet.t] (or a [.layer]), return the lower bounds of its 'e
      (errors) and 'r (services) parameters.
    - [path_name]: alias for [Path.name] — kept here so future drift in [Path]
      is localised too. *)

#if OCAML_VERSION < (5, 4, 1) || OCAML_VERSION >= (5, 5, 0)
#error "hamlet-lint currently supports only OCaml 5.4.1"
#endif

(* ------------------------------------------------------------------ *)
(*  Row extraction                                                    *)
(* ------------------------------------------------------------------ *)

(** Extract the [Rpresent] tag names from a polymorphic variant row. Returns
    [None] if the type is not a [Tvariant]. Absent and [Reither] fields are
    deliberately excluded: they are not part of the definite lower bound. *)
let row_lower_bound (te : Types.type_expr) : string list option =
  let te = Ctype.expand_head Env.empty te in
  match Types.get_desc te with
  | Tvariant rd ->
      let (Types.Row { fields; _ }) = Types.row_repr rd in
      let tags =
        List.filter_map
          (fun (name, f) ->
            match Types.row_field_repr f with
            | Rpresent _ -> Some name
            | Reither _ | Rabsent -> None)
          fields
      in
      Some (List.sort compare tags)
  | _ -> None

(** Follow a [type_expr] to its head [Tconstr], stripping [Tlink]s and similar
    through [get_desc]. Returns the path and type args, or [None]. *)
let head_constr (te : Types.type_expr) =
  match Types.get_desc te with
  | Tconstr (p, args, _) -> Some (p, args)
  | _ -> None

(** For a type of shape [('a, 'e, 'r) Hamlet.t] or [('a, 'e, 'r) Layer.t],
    return [(errors_lb, services_lb)]. The lower bounds are [None] when the
    corresponding parameter is a free row variable (not a concrete [Tvariant]).
*)
let effect_type_row_lbs (te : Types.type_expr) :
    string list option * string list option =
  match head_constr te with
  | Some (_p, args) when List.length args >= 3 -> (
      match args with
      | [ _a; e; r ] -> (row_lower_bound e, row_lower_bound r)
      | _ :: e :: r :: _ -> (row_lower_bound e, row_lower_bound r)
      | _ -> (None, None))
  | _ -> (None, None)

let path_name = Path.name

(** Split a dune-mangled module name [Foo__Bar__Baz] into its components
    [["Foo"; "Bar"; "Baz"]]. Non-mangled names split into a singleton. Used to
    canonicalise [cmt_modname] values against user-visible dotted paths. *)
let split_mangled (s : string) : string list =
  let len = String.length s in
  let rec loop start i acc =
    if i + 1 >= len then List.rev (String.sub s start (len - start) :: acc)
    else if s.[i] = '_' && s.[i + 1] = '_' then
      let seg = String.sub s start (i - start) in
      loop (i + 2) (i + 2) (seg :: acc)
    else loop start (i + 1) acc
  in
  if len = 0 then [ "" ] else loop 0 0 []

let loc_of_location (l : Location.t) : Hamlet_lint_schema.Schema.loc =
  let open Lexing in
  let p = l.loc_start in
  { file = p.pos_fname; line = p.pos_lnum; col = p.pos_cnum - p.pos_bol }
