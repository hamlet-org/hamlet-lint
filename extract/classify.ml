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

let catch_path = "Hamlet.Combinators.catch"
let provide_path = "Hamlet.Combinators.provide"

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

(** Resolve a callee to one of [`Catch | `Provide | `Other]. The bare
    [Path.last] fallback ([catch] / [provide] without the [Hamlet.Combinators.]
    prefix, e.g. inside [let open]) requires the structural Hamlet fingerprint
    on [val_type] to avoid grabbing unrelated [catch] / [provide] symbols from
    other libraries. *)
let classify_path (path : Path.t) (val_type : Types.type_expr) =
  let n = Path.name path in
  if n = catch_path then `Catch
  else if n = provide_path then `Provide
  else
    match Path.last path with
    | "catch" when mentions_hamlet_t val_type -> `Catch
    | "provide" when mentions_hamlet_t val_type -> `Provide
    | _ -> `Other
