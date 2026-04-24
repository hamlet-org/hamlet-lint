(** Extract the upstream effect's row tags for the slot the combinator targets:

    - [`Catch] looks at slot 1 ([`'e`], the errors row).
    - [`Provide] looks at slot 2 ([`'r`], the services row).

    The {b key trick} for accuracy: when upstream is a let-bound variable, the
    variable's [Texp_ident] carries the value description's [val_type], which is
    the {i pre-widening} narrow row the upstream was given at its definition
    site. The widening that fools OCaml's covariant subtyping mutates the
    [exp_type] at the call site only. So reading [val_type] from [Texp_ident]
    gives us the truth.

    For inline upstreams (no let-binding) we fall back to [exp_type], which is
    already widened — this is the documented limitation. The workaround is to
    bind the upstream: [let eff = ... in catch eff ~f:...] *)

open Typedtree

(** Return the upstream's "as declared" type. For a let-bound [Texp_ident], take
    the variable's [val_type]; otherwise take the expression's instantiated
    [exp_type] (best-effort, may be widened). *)
let declared_type (e : expression) : Types.type_expr =
  match e.exp_desc with Texp_ident (_, _, vd) -> vd.val_type | _ -> e.exp_type

(** Extract slot [slot] (0-based) of a [(_, _, _) Hamlet.t] application. Returns
    [None] if [ty] is not a 3-arg [t]-shaped [Tconstr] rooted in the Hamlet
    library. The Hamlet-root check (via {!Classify.path_root_is_hamlet})
    prevents the extractor from grabbing arguments off unrelated 3-arg [t] types
    from other libraries. *)
let hamlet_slot (ty : Types.type_expr) ~(slot : int) : Types.type_expr option =
  let ty = Ctype.expand_head Env.empty ty in
  match Types.get_desc ty with
  | Tconstr (path, args, _) ->
      if
        List.length args = 3
        && (Path.name path = "Hamlet.t"
           || (Path.last path = "t" && Classify.path_root_is_hamlet path))
      then Some (List.nth args slot)
      else None
  | _ -> None

(** Tag list reachable from upstream's row at the slot relevant to [kind].
    [None] when upstream's type does not look like [(_, _, _) Hamlet.t]. *)
let row_tags (up : expression) ~(kind : [ `Catch | `Provide ]) :
    string list option =
  let slot = match kind with `Catch -> 1 | `Provide -> 2 in
  match hamlet_slot (declared_type up) ~slot with
  | Some ty -> Some (Tags.present_tags ty)
  | None -> None
