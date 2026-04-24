(** Classify a [Texp_apply]'s callee as one of the two combinators we monitor —
    [Hamlet.Combinators.catch] / [.provide] — or as something else.

    Two strategies in order:

    1. {b Path matching}. [Path.name] gives the canonical dotted name; if it
    equals the full path, we accept. This handles direct references like
    [Hamlet.Combinators.catch].

    2. {b Structural fingerprint}. When a user writes
    [let open Hamlet.Combinators in catch ...] or
    [let module HC = Hamlet.Combinators in HC.catch ...], the path loses its
    [Hamlet.Combinators.] prefix. [Path.last] still gives us the bare name, so
    we fall back to checking that the value's [val_type] mentions a [Hamlet.t]
    type constructor anywhere in its surface — a structural signature unique to
    combinators. *)

(** All combinators we monitor. For each: which slot of the upstream's
    [Hamlet.t] / [Layer.t] carries the row to compare against ([`Catch] = slot 1
    = errors row, [`Provide] = slot 2 = services row), and whether the handler
    is single-arg or curried (curried handlers like
    [Layer.provide_to_effect ~h:(fun impl (x : [%hamlet.ts ...]) -> ...)] have
    the annotation on the SECOND parameter). *)

let single_arg_paths : (string * [ `Catch | `Provide ]) list =
  [
    ("Hamlet.Combinators.catch", `Catch);
    ("Hamlet.Combinators.provide", `Provide);
    ("Hamlet.Combinators.map_error", `Catch);
    ("Hamlet.Layer.catch", `Catch);
  ]

let curried_paths : (string * [ `Catch | `Provide ]) list =
  [
    ("Hamlet.Layer.provide_to_effect", `Provide);
    ("Hamlet.Layer.provide_to_layer", `Provide);
    ("Hamlet.Layer.provide_merge_to_layer", `Provide);
  ]

(* For the structural fingerprint fallback: the bare name → kind / arity.
   [Path.last] gives just the function name (no module prefix); we still
   gate on [mentions_hamlet_t val_type] in [classify_path] to avoid
   matching unrelated APIs. *)
let single_arg_lasts : (string * [ `Catch | `Provide ]) list =
  [ ("catch", `Catch); ("provide", `Provide); ("map_error", `Catch) ]

let curried_lasts : (string * [ `Catch | `Provide ]) list =
  [
    ("provide_to_effect", `Provide);
    ("provide_to_layer", `Provide);
    ("provide_merge_to_layer", `Provide);
  ]

(** Walk a [Path.t] up to its root identifier and check whether that identifier
    is exactly the Hamlet library — either [Hamlet] (the canonical name) or
    [Hamlet__<X>] (the dune-mangled wrapper for submodules). Anything else,
    including unrelated names that happen to start with "Hamlet" (e.g.
    [Hamlet_lint], [HamletFoo]), is rejected. Used to confirm a structural
    fingerprint actually came from the Hamlet library, not from some unrelated
    API. *)
let rec path_root_is_hamlet : Path.t -> bool = function
  | Path.Pident id ->
      let n = Ident.name id in
      n = "Hamlet" || (String.length n >= 8 && String.sub n 0 8 = "Hamlet__")
  | Path.Pdot (p, _) -> path_root_is_hamlet p
  | Path.Papply (p, _) -> path_root_is_hamlet p
  | Path.Pextra_ty (p, _) -> path_root_is_hamlet p

(** Recursively search a type for a 3-arg [t] constructor whose path is rooted
    in the Hamlet library. The 3-arg arity matches Hamlet's
    [type (+'a, +'e, +'r) t] signature; the Hamlet-root check rules out
    unrelated APIs that happen to expose a 3-arg [t] (a real source of false
    positives if the check is only on arity). Memoisation via [Types.get_id]
    avoids re-walking shared sub-trees. *)
let mentions_hamlet_t (ty : Types.type_expr) : bool =
  let seen = Hashtbl.create 16 in
  let rec go ty =
    if Hashtbl.mem seen (Types.get_id ty) then false
    else begin
      Hashtbl.add seen (Types.get_id ty) ();
      let ty = Ctype.expand_head Env.empty ty in
      match Types.get_desc ty with
      | Tconstr (p, args, _) ->
          (Path.last p = "t" && List.length args = 3 && path_root_is_hamlet p)
          || List.exists go args
      | Tarrow (_, dom, codom, _) -> go dom || go codom
      | Ttuple parts -> List.exists (fun (_, t) -> go t) parts
      | _ -> false
    end
  in
  go ty

(** Result of classifying a callee: which slot to inspect ([`Catch] = errors,
    [`Provide] = services), and whether the handler is curried (annotation on
    the second parameter, as in [Layer.provide_to_effect]). *)
type classification =
  | Single of [ `Catch | `Provide ]
  | Curried of [ `Catch | `Provide ]
  | Other

(** Returns [true] when [vd.val_loc] points to Hamlet's published surface (the
    top-level [hamlet.mli] / [hamlet.ml] re-exports). Used to disambiguate the
    [let module HC = Hamlet.Combinators in HC.catch] alias case from a
    user-defined [let catch eff ~f = ...]: both have a non-Hamlet [Path.t] root,
    but only the former's [val_loc] points at [hamlet.mli]. *)
let val_loc_in_hamlet_surface (vd : Types.value_description) : bool =
  let f = Filename.basename vd.val_loc.loc_start.pos_fname in
  f = "hamlet.mli" || f = "hamlet.ml"

(** Resolve a callee to a {!classification}. The bare [Path.last] fallback fires
    only when the callee provably comes from Hamlet — either the path itself is
    rooted in [Hamlet] / [Hamlet__*] (covers [let open]) or the value's
    definition site is in Hamlet's surface module (covers
    [let module HC = Hamlet.Combinators in HC.catch] where the path root is the
    local alias). Without one of these signals a user-defined helper named
    [catch] / [provide] / [map_error] / [provide_to_*] could be misclassified as
    the real combinator (regression: [edge_cases.ml::e11]). *)
let classify_path
    (path : Path.t)
    (val_type : Types.type_expr)
    (vd : Types.value_description) =
  let n = Path.name path in
  match List.assoc_opt n single_arg_paths with
  | Some kind -> Single kind
  | None -> (
      match List.assoc_opt n curried_paths with
      | Some kind -> Curried kind
      | None -> (
          if not (path_root_is_hamlet path || val_loc_in_hamlet_surface vd) then
            Other
          else
            let last = Path.last path in
            match List.assoc_opt last single_arg_lasts with
            | Some kind when mentions_hamlet_t val_type -> Single kind
            | _ -> (
                match List.assoc_opt last curried_lasts with
                | Some kind when mentions_hamlet_t val_type -> Curried kind
                | _ -> Other)))
