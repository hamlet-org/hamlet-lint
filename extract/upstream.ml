(** Extract the upstream effect's row tags for the slot the combinator targets:

    - [`Catch] looks at slot 1 ([`'e`], the errors row).
    - [`Provide] looks at slot 2 ([`'r`], the services row).

    The {b key trick} for accuracy: when upstream is a let-bound variable, the
    variable's [Texp_ident] carries the value description's [val_type], which is
    the {i pre-widening} narrow row the upstream was given at its definition
    site. The widening that fools OCaml's covariant subtyping mutates the
    [exp_type] at the call site only. So reading [val_type] from [Texp_ident]
    gives us the truth.

    For inline upstreams (no let-binding) we used to fall back unconditionally
    to [exp_type], which is already widened — the LIMITATIONS §1.1
    false-negative documented prior to this module's recursive extension.

    {1 Recursive residual for chained inline combinators}

    When upstream is itself a [Texp_apply] of a known combinator (catch /
    provide / their Layer counterparts), we compute the inner combinator's
    {b residual row} on the slot the OUTER cares about, by recursing. The catch
    / provide effect on each slot:

    {v
    Combinator                     Slot 1 (errors)            Slot 2 (services)
    ------------------------------ ------------------------- ---------------------------
    Combinators.catch              handler-driven            pass-through (recurse)
    Combinators.map_error          handler codomain (skip)   pass-through (recurse)
    Combinators.provide            pass-through (recurse)    handler-driven
    Layer.catch                    handler-driven (skip)     pass-through (recurse)
    Layer.provide_to_effect        pass-through (recurse)    handler-driven
    Layer.provide_to_layer         pass-through (recurse)    handler-driven
    Layer.provide_merge_to_layer   pass-through (recurse)    handler-driven
    v}

    "Handler-driven" cases that we successfully detect:

    - {b catch} with pure-propagate handler (every arm is [failure (alias)] —
      the [%hamlet.propagate_e] expansion or hand-rolled equivalent): residual
      on slot 1 = inner upstream's residual on slot 1.
    - {b provide} with pure-need handler (every arm is [Dispatch.need (alias)]):
      residual on slot 2 = inner upstream's residual on slot 2 (handler is a
      no-op, equivalent to [%hamlet.propagate_s] for all tags).
    - {b provide} with pure-give handler (every arm is [<X>.Tag.give alias _]):
      residual on slot 2 = inner upstream's residual on slot 2, minus the union
      of give-tags collected from the arm patterns.

    Anything else (handler shape we don't recognise, [Layer.catch] whose handler
    returns [Layer.make ...] rather than [failure], [map_error] whose handler
    returns a tag value, etc.) → fallback to widened [exp_type], same
    false-negative posture as before.

    Slot pass-through is unconditional: an outer catch over an inner provide
    sees inner provide as a slot-1 pass-through (provide doesn't touch errors),
    and vice versa. *)

open Typedtree

(** Args helpers — local copies of {!Walker.extract_upstream} /
    {!Walker.extract_handler}, kept here to avoid a circular dependency between
    [upstream.ml] (which now needs to inspect arg lists for recursion) and
    [walker.ml] (which uses [upstream.ml]). The walker delegates to these in
    {!Walker.try_candidate} too.

    Both helpers ignore [Omitted] arg slots — those represent the
    not-yet-provided positions of a partial application, and the [unstage]
    machinery below splices in the missing positional value by combining the
    outer apply's arg list with the inner partial's. *)
let extract_upstream args =
  List.find_map
    (fun (lbl, a) ->
      match (lbl, a) with Asttypes.Nolabel, Arg e -> Some e | _ -> None)
    args

let extract_handler args =
  List.find_map
    (fun (lbl, a) ->
      match (lbl, a) with
      | Asttypes.Labelled ("f" | "h"), Arg e -> Some e
      | _ -> None)
    args

(** Unstage a [Texp_apply] so that downstream classification works for both the
    direct form ([catch eff ~f:h]) and the partial-then-applied form that the
    [%revapply] [|>] pipe produces ([eff |> catch ~f:h] becomes
    [Texp_apply (<partial catch ~f:h>, [Nolabel, Arg eff])] at typedtree level —
    see ppx-hamlet test/cases/chained_cases dump).

    Returns [Some (ident_callee, combined_args)] when:
    - The outer apply's callee is itself a [Texp_apply] whose callee is a
      [Texp_ident], and at least one positional slot in the inner apply is
      [Omitted] (signal that this is a partial waiting for upstream).
    - We can splice the outer's positional [Arg]s into the [Omitted] slots of
      the inner, producing a canonical full-arg list.

    Returns [None] for the direct form (no unstaging needed) or for shapes that
    don't fit (multi-level partial chains, named-arg-only outer call, etc.). The
    walker / recursion fall back to the direct path. *)
let unstage_apply (e : Typedtree.expression) :
    (Typedtree.expression * (Asttypes.arg_label * Typedtree.apply_arg) list)
    option =
  let open Typedtree in
  match e.exp_desc with
  | Texp_apply (outer_callee, outer_args) -> (
      match outer_callee.exp_desc with
      | Texp_apply (inner_callee, inner_args) -> (
          match inner_callee.exp_desc with
          | Texp_ident _ ->
              (* Splice outer positional Args into inner Omitted positional
                 slots. Tracks an outer-arg cursor; named outer args (rare
                 but allowed by OCaml when the inner partial omitted a
                 named slot too) are appended verbatim. *)
              let outer_pos_args =
                List.filter_map
                  (fun (lbl, a) ->
                    match (lbl, a) with
                    | Asttypes.Nolabel, Arg _ -> Some a
                    | _ -> None)
                  outer_args
              in
              let outer_named_args =
                List.filter
                  (fun (lbl, _) ->
                    match lbl with Asttypes.Nolabel -> false | _ -> true)
                  outer_args
              in
              let cursor = ref outer_pos_args in
              let spliced =
                List.map
                  (fun (lbl, a) ->
                    match (lbl, a) with
                    | Asttypes.Nolabel, Omitted _ -> (
                        match !cursor with
                        | [] -> (lbl, a)
                        | next :: rest ->
                            cursor := rest;
                            (lbl, next))
                    | _ -> (lbl, a))
                  inner_args
              in
              if !cursor = [] && outer_named_args = [] then
                Some (inner_callee, spliced)
              else if !cursor = [] then
                Some (inner_callee, spliced @ outer_named_args)
              else
                (* Some outer positional args couldn't be placed — shape
                   doesn't match a clean partial-then-apply. *)
                None
          | _ -> None)
      | _ -> None)
  | _ -> None

(** Walk a type to slot [slot] of a [(_, _, _) Hamlet.t] / [Layer.t]
    application. Returns [None] when the type is not a 3-arg Hamlet-rooted [t].
    The Hamlet-root check (via {!Classify.path_root_is_hamlet}) prevents
    grabbing arguments off unrelated 3-arg [t] types. *)
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

(** Tags read off the slot of [ty] when [ty] is recognised as a Hamlet/Layer
    [t]. Wraps [hamlet_slot] + [Tags.present_tags]. *)
let tags_at_slot (ty : Types.type_expr) ~(slot : int) : string list option =
  match hamlet_slot ty ~slot with
  | Some t -> Some (Tags.present_tags t)
  | None -> None

(** Set difference preserving the order of [a]. Tag lists are tiny (single
    digits) so a quadratic implementation is fine. *)
let diff (a : string list) (b : string list) : string list =
  List.filter (fun x -> not (List.mem x b)) a

(** Recursive residual computation. [slot] is the slot the OUTER combinator
    cares about (1 = errors, 2 = services). For a let-bound [Texp_ident] we read
    [vd.val_type]; for an inline [Texp_apply] of a known combinator we recurse,
    propagating through pass-through slots and handling the "handler-driven"
    slots when the handler matches a recognised pure shape. *)
let rec residual ~(slot : int) (e : expression) : string list option =
  match e.exp_desc with
  | Texp_ident (_, _, vd) -> tags_at_slot vd.val_type ~slot
  | Texp_apply (callee, args) -> classify_and_recurse ~slot e ~callee ~args
  | _ -> tags_at_slot e.exp_type ~slot

(** Common direct-form handler shared by the direct-callee branch and the
    unstaged callee branch. [outer_e] is always the original outer apply
    expression, so the widened-fallback location stays accurate. *)
and classify_and_recurse
    ~slot
    (outer_e : expression)
    ~(callee : expression)
    ~(args : (Asttypes.arg_label * apply_arg) list) : string list option =
  match callee.exp_desc with
  | Texp_ident (path, _, vd) -> (
      let kind_opt =
        match Classify.classify_path path vd.val_type vd with
        | Single k -> Some (k, 0)
        | Curried k -> Some (k, 1)
        | Other -> None
      in
      match kind_opt with
      | None -> tags_at_slot outer_e.exp_type ~slot
      | Some (kind, peel) -> residual_through ~slot ~kind ~peel args outer_e)
  | Texp_apply _ -> (
      (* The pipe form [eff |> catch ~f:H] yields a staged apply: outer
         apply with one positional [Arg eff] over an inner apply (the
         partial [catch ~f:H]). Unstage and try again. *)
      match unstage_apply outer_e with
      | Some (inner_callee, combined_args) ->
          classify_and_recurse ~slot outer_e ~callee:inner_callee
            ~args:combined_args
      | None -> tags_at_slot outer_e.exp_type ~slot)
  | _ -> tags_at_slot outer_e.exp_type ~slot

(** Residual through one inner combinator application. The combinator kind
    determines which slot it touches:

    - [`Catch] touches slot 1 (errors), passes slot 2 (services) through.
    - [`Provide] touches slot 2 (services), passes slot 1 (errors) through.

    For pass-through slots we recurse on the inner positional upstream. For
    touched slots we delegate to the handler-shape detector and either recurse
    (pure-propagate / pure-need) or arithmetic-then-recurse (pure-give), or fall
    back. *)
and residual_through ~slot ~kind ~peel args (outer_e : expression) :
    string list option =
  let upstream = extract_upstream args in
  let handler = extract_handler args in
  let pass_through () =
    match upstream with
    | Some up -> residual ~slot up
    | None -> tags_at_slot outer_e.exp_type ~slot
  in
  let touched () =
    match (kind, handler, upstream) with
    | `Catch, Some h, Some up -> (
        match Propagate.classify_catch_handler ~peel h with
        | Catch_pure_propagate -> residual ~slot up
        | Catch_other -> tags_at_slot outer_e.exp_type ~slot)
    | `Provide, Some h, Some up -> (
        match Propagate.classify_provide_handler ~peel h with
        | Provide_residual discharged -> (
            match residual ~slot up with
            | Some up_tags -> Some (diff up_tags discharged)
            | None -> None)
        | Provide_other -> tags_at_slot outer_e.exp_type ~slot)
    | _ -> tags_at_slot outer_e.exp_type ~slot
  in
  match (kind, slot) with
  | `Catch, 1 -> touched ()
  | `Catch, _ -> pass_through ()
  | `Provide, 2 -> touched ()
  | `Provide, _ -> pass_through ()

(** Tag list reachable from upstream's row at the slot relevant to [kind].
    [None] when neither the recursion nor the fallback can recognise a
    Hamlet/Layer [t] slot. Wrapper kept for API stability with the existing
    walker. *)
let row_tags (up : expression) ~(kind : [ `Catch | `Provide ]) :
    string list option =
  let slot = match kind with `Catch -> 1 | `Provide -> 2 in
  residual ~slot up
