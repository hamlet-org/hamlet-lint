(** Detectors for "pure-propagate" handler shapes.

    A handler counts as "pure-propagate" when every case forwards the matched
    tag verbatim — no row arithmetic happens at the case level beyond what the
    PPX-generated [%hamlet.propagate_e] / [%hamlet.propagate_s] arms do.
    Typed-tree shape verified against fixtures (see test/cases/widening_cases.ml
    lines 26 / 38 / 53 / 66 dumped via the one-off /tmp/dump_propagate during
    dev):

    - per-arm pattern: [Tpat_value (Tpat_alias (<inner_pat>, var, _, _, _))],
      where [<inner_pat>] is either a single [Tpat_variant] or a [Tpat_or] tree
      of variants (cross-CU union types lower to or-patterns).
    - per-arm RHS for propagate_e:
      [Texp_apply (Hamlet.Combinators.failure, [Nolabel, Arg <Texp_ident var>])].
    - per-arm RHS for propagate_s:
      [Texp_apply (Hamlet.Dispatch.need, [Nolabel, Arg <Texp_ident var>])].
    - per-arm RHS for "give" (a service implementation handed to the runtime):
      [Texp_apply (<X>.Tag.give, [Nolabel, Arg <Texp_ident var>; Nolabel, _])].

    The detector is intentionally conservative. Anything off-shape returns
    [Mixed] and the caller falls back to the widened [exp_type] (current
    behavior). False negatives only — never false positives. *)

open Typedtree

(** Normalized arm view: pattern (kind-polymorphic), optional guard, RHS.
    [Tfunction_cases] yields [value general_pattern] arms; [Texp_match] yields
    [computation general_pattern] arms. Both feed the same downstream
    classifiers, which only inspect via [_ general_pattern]. *)
type arm = Arm : 'k general_pattern * expression option * expression -> arm

(** Reach the case list across the three handler shapes that expose cases:

    - [Texp_function (_, Tfunction_cases { cases; _ })] — whole-function
      annotation form ([function | ... : [%hamlet.te _] -> _]). Cases here are
      [value case list] — pattern is [value general_pattern].
    - [Texp_function (_, Tfunction_body (Texp_match (_, cases, _, _)))] —
      param-annotation or scrutinee-annotation form, body is a single match.
      Cases here are [computation case list].
    - bare [Texp_match] — handler that is itself a match expression (uncommon
      but seen in user code). Same case type as above.

    Returns [None] when the handler shape does not expose cases — e.g.
    [Texp_ident] (named handler), [Texp_apply] (apply-built handler),
    multi-statement function bodies. The recursion stops here and the caller
    falls back. *)
let arms_of_handler (h : expression) : arm list option =
  let of_value_cases (cs : value case list) : arm list =
    List.map (fun (c : value case) -> Arm (c.c_lhs, c.c_guard, c.c_rhs)) cs
  in
  let of_comp_cases (cs : computation case list) : arm list =
    List.map
      (fun (c : computation case) -> Arm (c.c_lhs, c.c_guard, c.c_rhs))
      cs
  in
  match h.exp_desc with
  | Texp_function (_, Tfunction_cases { cases; _ }) ->
      Some (of_value_cases cases)
  | Texp_function
      (_, Tfunction_body { exp_desc = Texp_match (_, cases, _, _); _ }) ->
      Some (of_comp_cases cases)
  | Texp_match (_, cases, _, _) -> Some (of_comp_cases cases)
  | _ -> None

(** Strip [Texp_function] layers off a curried handler. Mirrors
    [Handler.peel_outer]: each stripped layer must have one parameter and a
    [Tfunction_body] (not [Tfunction_cases], which would consume the annotated
    parameter). Returns [None] when the layers cannot be peeled (handler shape
    doesn't match), so the caller falls back. *)
let rec peel_outer (h : expression) (n : int) : expression option =
  if n = 0 then Some h
  else
    match h.exp_desc with
    | Texp_function ([ _ ], Tfunction_body inner) -> peel_outer inner (n - 1)
    | _ -> None

(** Collect the variant tags reachable from a pattern, descending [Tpat_or]
    branches and unwrapping [Tpat_value]. Returns [None] if any leaf is not a
    [Tpat_variant] / [Tpat_or] / [Tpat_value] — i.e. the case matches more than
    just polymorphic-variant tags ([Tpat_any], [Tpat_var], constants, etc.), so
    we can't soundly say "this case discharges exactly tag X". *)
let rec collect_variant_tags : type k. k general_pattern -> string list option =
 fun p ->
  match p.pat_desc with
  | Tpat_value v ->
      collect_variant_tags (v : tpat_value_argument :> value general_pattern)
  | Tpat_alias (inner, _, _, _, _) -> collect_variant_tags inner
  | Tpat_variant (label, _, _) -> Some [ label ]
  | Tpat_or (a, b, _) -> (
      match (collect_variant_tags a, collect_variant_tags b) with
      | Some la, Some lb -> Some (la @ lb)
      | _ -> None)
  | _ -> None

(** Extract the alias variable from the case pattern: ["e"] for propagate_e,
    ["w"] for propagate_s, or whatever the user chose. The PPX always uses
    [as e] / [as w], but a hand-written handler may use a different name — we
    read it dynamically. Skips [Tpat_value] wrappers. *)
let rec alias_var : type k. k general_pattern -> Ident.t option =
 fun p ->
  match p.pat_desc with
  | Tpat_value v -> alias_var (v : tpat_value_argument :> value general_pattern)
  | Tpat_alias (_, id, _, _, _) -> Some id
  | _ -> None

(** Is [e] a [Texp_ident] referencing the local name [v]? Used to confirm that
    the RHS of a propagate arm passes back the same alias the pattern bound, not
    some other expression (which would mean the handler isn't pure-propagate).
*)
let is_ident_var (e : expression) (v : Ident.t) : bool =
  match e.exp_desc with
  | Texp_ident (Path.Pident id, _, _) -> Ident.same id v
  | _ -> false

(** True when [path] is rooted in a [__Hamlet_rest_*] module — the PPX-
    generated cross-CU rest alias (see ppx_hamlet.ml is_cross_cu_rest_alias at
    line 1161). The expose helper lives inside one of these aliases, so a path
    like [M.__Hamlet_rest_Database__.expose_t_<hash>] passes; an unrelated user
    [let expose_foo e = ...] does not. *)
let path_through_hamlet_rest_alias (path : Path.t) : bool =
  let prefix = "__Hamlet_rest_" in
  let starts_with s =
    String.length s > String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  in
  match path with
  | Path.Pdot (parent, _) -> starts_with (Path.last parent)
  | _ -> false

(** Match the cross-CU expose wrapping:
    [Texp_apply (<expose_*>, [Nolabel, Arg <Texp_ident var with Texp_coerce in
     exp_extra>])]. The PPX-generated [(e :> M.t_<hash>)] coercion lives in
    [exp_extra], not [exp_desc] — at typedtree level the expression payload IS
    the bare [Texp_ident]. So we just check the desc. The expose function is
    generated by the producer module; its [Path.last] starts with ["expose_"]
    AND its parent module's last segment starts with ["__Hamlet_rest_"]. The
    parent-module gate (vs. just the name prefix) prevents misclassifying
    unrelated user-defined helpers that happen to be named [expose_*]. *)
let is_expose_of_var (e : expression) (v : Ident.t) : bool =
  match e.exp_desc with
  | Texp_apply (callee, [ (Asttypes.Nolabel, Arg arg) ]) -> (
      match callee.exp_desc with
      | Texp_ident (path, _, _) ->
          let last = Path.last path in
          String.length last >= 7
          && String.sub last 0 7 = "expose_"
          && path_through_hamlet_rest_alias path
          && is_ident_var arg v
      | _ -> false)
  | _ -> false

(** Recognise [Hamlet.Combinators.failure] by canonical [Path.name]. User
    aliases ([let fail = failure], [let open Hamlet.Combinators]) are
    intentionally unsupported — see LIMITATIONS §6. *)
let is_failure_callee (path : Path.t) : bool =
  Path.name path = "Hamlet.Combinators.failure"

(** Recognise [Hamlet.Dispatch.need] by canonical [Path.name]. Aliases
    intentionally unsupported (LIMITATIONS §6). *)
let is_dispatch_need_callee (path : Path.t) : bool =
  Path.name path = "Hamlet.Dispatch.need"

(** Recognise PPX-generated [<X>.Tag.give] by structural shape:
    [Path.last = "give"] AND parent module's last segment is ["Tag"]. The
    [%hamlet.service] PPX always wraps give in a module called Tag (one per
    declared service). Pathological wrappers (user-defined `module Tag = struct
    let give = ... end`) are out of scope. *)
let is_tag_give_callee (path : Path.t) : bool =
  Path.last path = "give"
  &&
  match path with
  | Path.Pdot (parent, _) -> Path.last parent = "Tag"
  | _ -> false

(** Result of classifying one provide handler arm. *)
type provide_arm =
  | Pa_give of string list
      (** discharges these tag(s) (one per Tpat_or leaf) *)
  | Pa_need of string list  (** re-needs these tag(s) — pass-through *)
  | Pa_unknown
      (** anything else: the handler is not pure-propagate / pure-discharge *)

(** Classify the RHS of one provide handler arm. Two recognised shapes:
    - [Texp_apply (Hamlet.Dispatch.need, [Arg (Texp_ident alias)])] → Pa_need
    - [Texp_apply (<X>.Tag.give, [Arg (Texp_ident alias); _])] → Pa_give

    Aliased forms ([let need = Dispatch.need], [let open ...], etc.) are out of
    scope (LIMITATIONS §6). Tags are taken from the case pattern. *)
let classify_provide_arm (Arm (lhs, guard, rhs) : arm) : provide_arm =
  if guard <> None then Pa_unknown
  else
    match (alias_var lhs, rhs.exp_desc) with
    | Some var, Texp_apply (callee, args) -> (
        let first_arg_is_var =
          match args with
          | (Asttypes.Nolabel, Arg arg) :: _ -> is_ident_var arg var
          | _ -> false
        in
        if not first_arg_is_var then Pa_unknown
        else
          match callee.exp_desc with
          | Texp_ident (path, _, _) -> (
              match collect_variant_tags lhs with
              | None -> Pa_unknown
              | Some tags ->
                  if is_dispatch_need_callee path then Pa_need tags
                  else if is_tag_give_callee path then Pa_give tags
                  else Pa_unknown)
          | _ -> Pa_unknown)
    | _ -> Pa_unknown

(** Result of classifying a catch handler. *)
type catch_handler =
  | Catch_pure_propagate
      (** every arm is [failure (alias)] (or cross-CU
          [failure (expose (alias :> _))]) *)
  | Catch_other  (** anything else — fallback to widened [exp_type] *)

(** Classify a catch handler. Returns [Catch_pure_propagate] iff every case has
    a guard-free pattern that aliases a polymorphic-variant pattern, and a RHS
    of either:
    - [Texp_apply (Hamlet.Combinators.failure, [Nolabel, Arg (Texp_ident
       alias)])] — same-CU
    - [Texp_apply (Hamlet.Combinators.failure, [Nolabel, Arg (<expose> (alias :>
       _))])] — cross-CU

    The PPX-generated [%hamlet.propagate_e] expansion always produces this
    shape; user-written handlers that hand-roll the same shape are also covered.
*)
let classify_catch_handler ~peel (h : expression) : catch_handler =
  match peel_outer h peel with
  | None -> Catch_other
  | Some inner -> (
      match arms_of_handler inner with
      | None -> Catch_other
      | Some arms ->
          let arm_is_pure_propagate (Arm (lhs, guard, rhs) : arm) : bool =
            if guard <> None then false
            else
              match (alias_var lhs, rhs.exp_desc) with
              | Some var, Texp_apply (callee, [ (Asttypes.Nolabel, Arg arg) ])
                ->
                  let path_is_failure =
                    match callee.exp_desc with
                    | Texp_ident (path, _, _) -> is_failure_callee path
                    | _ -> false
                  in
                  path_is_failure
                  && (is_ident_var arg var || is_expose_of_var arg var)
              | _ -> false
          in
          if arms <> [] && List.for_all arm_is_pure_propagate arms then
            Catch_pure_propagate
          else Catch_other)

(** Result of classifying a provide handler. *)
type provide_handler =
  | Provide_residual of string list
      (** every arm is [Pa_give] or [Pa_need]; residual on slot 2 = upstream
          slot 2 ∖ (union of give tags). Need arms re-emit and contribute
          nothing. *)
  | Provide_other
      (** at least one arm is [Pa_unknown] (custom dispatch, unrecognised shape)
          — fallback to widened [exp_type]. *)

(** Classify a provide handler. The recognised shape: every arm is either a
    [Dispatch.need alias] (re-emits, no-op on residual) or an
    [<X>.Tag.give alias _] (discharges the tags matched by the arm pattern).
    Mixed give+need is the common idiom (provide some services, propagate the
    rest). Any [Pa_unknown] arm — handler does something other than the two
    known dispatch primitives — collapses to [Provide_other]. *)
let classify_provide_handler ~peel (h : expression) : provide_handler =
  match peel_outer h peel with
  | None -> Provide_other
  | Some inner -> (
      match arms_of_handler inner with
      | None -> Provide_other
      | Some [] -> Provide_other
      | Some arms ->
          let classified = List.map classify_provide_arm arms in
          if List.exists (function Pa_unknown -> true | _ -> false) classified
          then Provide_other
          else
            let give_tags =
              List.concat_map (function Pa_give ts -> ts | _ -> []) classified
            in
            Provide_residual give_tags)
