(** Classify a [Texp_apply]'s callee as one of the monitored combinators or as
    something else.

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

(** Per-combinator descriptor: which row slot to inspect, how many outer handler
    parameters to strip before reading the annotation, which argument label
    carries the handler, and whether the handler's first parameter is wrapped in
    [Cause.t] (requiring one extra [Tconstr] descent to reach the row). *)
type info = {
  slot : [ `Catch | `Provide ];
  peel : int;
  handler_label : string;
      (** label name without leading [~], e.g. ["f"], ["handler"], ["filter"] *)
  wraps_in_cause : bool;
      (** true when the handler param is ['e Cause.t] and the row sits inside
          the [Tconstr] argument *)
  match_probe : bool;
      (** true for [catch_filter] / [catch_cause_filter]: the walker emits a
          second candidate comparing [~f]'s first parameter's declared row
          against the upper bound inferred from [~filter]'s body. *)
  implicit_upstream_tags : string list;
      (** tags the combinator silently introduces into upstream's row before the
          handler sees them, on top of whatever upstream's [val_type] declares.
          Currently only [Combinators.provide_scope] uses this (with
          [["Scope"]]) because its signature is generic on ['r_in] yet the
          runtime always seeds the [Scope] service for the handler to discharge.
          The walker unions these into [upstream] so the rule does not flag the
          handler's legitimate [#Scope.Tag.r] arm as widening when upstream is a
          let-bound ident whose [val_type] was generalised before reaching the
          call site. *)
}

(** Result of classifying a callee. *)
type classification = Match of info | Other

(** All combinators we monitor. Full canonical path → descriptor. *)
let paths : (string * info) list =
  [
    ( "Hamlet.Combinators.catch",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.map_error",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.catch_filter",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "filter";
        wraps_in_cause = false;
        match_probe = true;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.catch_cause",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = true;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.catch_cause_filter",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "filter";
        wraps_in_cause = true;
        match_probe = true;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.provide",
      {
        slot = `Provide;
        peel = 0;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Combinators.provide_scope",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [ "Scope" ];
      } );
    ( "Hamlet.Layer.catch",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Layer.catch_cause",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = true;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Layer.provide_to_effect",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Layer.provide_to_layer",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "Hamlet.Layer.provide_merge_to_layer",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
  ]

(** Structural-fingerprint fallback: bare [Path.last] → descriptor.
    [Layer.catch] / [Layer.catch_cause] share the bare names ["catch"] /
    ["catch_cause"] with their [Combinators.*] siblings — the
    [mentions_hamlet_t] gate (applied in [classify_path]) is sufficient to
    distinguish them from unrelated APIs; the descriptors are identical. *)
let lasts : (string * info) list =
  [
    ( "catch",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "map_error",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "catch_filter",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "filter";
        wraps_in_cause = false;
        match_probe = true;
        implicit_upstream_tags = [];
      } );
    ( "catch_cause",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "f";
        wraps_in_cause = true;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "catch_cause_filter",
      {
        slot = `Catch;
        peel = 0;
        handler_label = "filter";
        wraps_in_cause = true;
        match_probe = true;
        implicit_upstream_tags = [];
      } );
    ( "provide",
      {
        slot = `Provide;
        peel = 0;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "provide_scope",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [ "Scope" ];
      } );
    ( "provide_to_effect",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "provide_to_layer",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
    ( "provide_merge_to_layer",
      {
        slot = `Provide;
        peel = 1;
        handler_label = "handler";
        wraps_in_cause = false;
        match_probe = false;
        implicit_upstream_tags = [];
      } );
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
    [catch] / [provide] / [map_error] / [provide_to_*] etc. could be
    misclassified as the real combinator (regression: [edge_cases.ml::e11]). *)
let classify_path
    (path : Path.t)
    (val_type : Types.type_expr)
    (vd : Types.value_description) =
  let n = Path.name path in
  match List.assoc_opt n paths with
  | Some info -> Match info
  | None -> (
      if not (path_root_is_hamlet path || val_loc_in_hamlet_surface vd) then
        Other
      else
        let last = Path.last path in
        match List.assoc_opt last lasts with
        | Some info when mentions_hamlet_t val_type -> Match info
        | _ -> Other)
