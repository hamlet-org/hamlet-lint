(** Typedtree walker.

    v0.1.1 scope:

    - All eight combinators from §2.0 of the spec: [Combinators.provide],
      [Combinators.catch], [Combinators.map_error], [Layer.provide],
      [Layer.provide_layer], [Layer.provide_all], [Layer.catch], and the
      PPX-generated [<Mod>.Tag.provide].
    - Latent sites (wrapper functions whose subject effect has a free row
      variable of the enclosing function's parameter). Reports for these are
      deferred to the outer call site via a [latent_site]/[call_site] join
      handled by the analyzer.
    - [Texp_ident] handler resolution: same-module let-bindings (with
      alias-chain and nested [let]-in chasing up to depth 5) and cross-module
      references via a global table pre-built from every cmt in the load set.
    - Per-arm [body_introduces] on errors arms for direct [failure], direct
      [try_catch] with inline exn-handler, and PPX [<Mod>.Errors.make_*]
      constructors.

    Out of scope for v0.1.1 (explicit known limits — see [lint/README.md] §12):
    - Multi-level wrapper chains (wrapper calls wrapper). Only one level of
      indirection is joined.
    - Handlers defined in a module not present in the cmt load set. Silently
      skipped (with a [HAMLET_LINT_DEBUG=1] diagnostic).
    - Transitive helper introducers in errors arm bodies (a helper function that
      itself calls [failure]). Body-introducer scanning only sees direct
      [failure] / [try_catch] / PPX-[make_*] shapes. *)

open Typedtree
open Hamlet_lint_schema.Schema
module CT = Combinator_table

(** Peel one outer application layer. Used when a caller wants to see past an
    optional trailing argument — e.g. [wrap arg extra] should compare
    structurally as [wrap arg] against a parameter ident. Central helper so the
    three sites that do this (handler-site classification, call-site scan,
    promote pass) stay in sync. *)
let strip_one_apply (e : expression) : expression =
  match e.exp_desc with Texp_apply (inner, _) -> inner | _ -> e

(** Collect the (poly-variant) head tag names from a pattern. Handles
    [Tpat_variant], [Tpat_alias] (peels the alias), and [Tpat_or] (unions both
    sides). Returns [`Wildcard] if the pattern is [Tpat_any] or [Tpat_var] —
    those form the suppression case of §2.7 when their body is a Forward action.
*)
type pattern_kind = Ptags of string list | Pwildcard

let rec pattern_tags : type k. k general_pattern -> pattern_kind =
 fun p ->
  match p.pat_desc with
  | Tpat_variant (label, _, _) -> Ptags [ label ]
  | Tpat_alias (inner, _, _, _, _) -> pattern_tags inner
  | Tpat_value v -> pattern_tags (v :> value general_pattern)
  | Tpat_or (p1, p2, _) -> (
      match (pattern_tags p1, pattern_tags p2) with
      | Pwildcard, _ | _, Pwildcard -> Pwildcard
      | Ptags a, Ptags b -> Ptags (a @ b))
  | Tpat_any | Tpat_var _ -> Pwildcard
  | _ -> Ptags []

(** Strip a single [Texp_ident] from an application and return its [Path.t]. *)
let ident_path_of (e : expression) : Path.t option =
  match e.exp_desc with Texp_ident (p, _, _) -> Some p | _ -> None

(** {1 Handler resolution environment}

    Used by Priority 5 to resolve [Texp_ident] handler arguments back to the
    [Texp_function] body that the walker's arm classifier needs. *)

(** Per-module table of top-level (and nested [let]-body) bindings keyed by
    their [Ident.t], so same-module [Pident] references can be chased without
    string matching. *)
type local_env = (Ident.t * expression) list

(** Global table keyed by canonical dotted name (e.g.
    ["Hamlet_lint_fixture_cross_module_handler"; "Handler_mod"; "h"]), joined
    with "." for hashing. Values are the already-resolved [Texp_function]
    expressions of cross-module handler definitions. *)
type global_env = (string, expression) Hashtbl.t

type handler_env = { locals : local_env; globals : global_env }

let empty_globals () : global_env = Hashtbl.create 16

(** Canonicalise a [Path.t] to a dotted string key, using the same
    trailing-underscore stripping as [Combinator_table.path_to_dotted]. *)
let canonical_key_of_path (p : Path.t) : string option =
  match CT.path_to_dotted p with
  | Some xs -> Some (String.concat "." xs)
  | None -> None

(** Look up a top-level binding by its [Ident.t] in the local env. *)
let local_lookup (env : local_env) (id : Ident.t) : expression option =
  let rec loop = function
    | [] -> None
    | (id', e) :: _ when Ident.same id id' -> Some e
    | _ :: rest -> loop rest
  in
  loop env

(** Resolve a handler-argument [expression] down to a [Texp_function], chasing
    through in-module aliases, [Texp_let]-introduced locals, and cross-module
    [Pdot] references in the global table. Returns [None] if no [Texp_function]
    is reached within [depth] steps. *)
let rec resolve_to_function (env : handler_env) (depth : int) (e : expression) :
    expression option =
  if depth <= 0 then None
  else
    match e.exp_desc with
    | Texp_function _ -> Some e
    | Texp_ident (Path.Pident id, _, _) -> (
        match local_lookup env.locals id with
        | Some e' -> resolve_to_function env (depth - 1) e'
        | None -> None)
    | Texp_ident ((Path.Pdot _ as p), _, _) -> (
        match canonical_key_of_path p with
        | None -> None
        | Some key -> (
            match Hashtbl.find_opt env.globals key with
            | Some e' -> resolve_to_function env (depth - 1) e'
            | None -> None))
    | Texp_let (_, vbs, body) ->
        let extra =
          List.filter_map
            (fun vb ->
              match vb.vb_pat.pat_desc with
              | Tpat_var (id, _, _) -> Some (id, vb.vb_expr)
              | _ -> None)
            vbs
        in
        let env' = { env with locals = extra @ env.locals } in
        resolve_to_function env' (depth - 1) body
    | _ -> None

(** {1 Body introducer scanner (Priority 6)}

    For a catch / map_error / Layer.catch arm body, return the set of error tags
    introduced directly by the body via recognised shapes:

    - [Combinators.failure (`Tag)] — direct literal variant.
    - [Combinators.failure (Foo.Errors.make_<n> ...)] — PPX constructor,
      heuristically mapped to a tag by strip-prefix+capitalise.
    - [Combinators.try_catch f (fun _ -> `Tag)] — inline exn handler returning a
      direct literal variant.

    Unrecognised shapes contribute nothing (conservative — see §2.3.b calculus:
    being too liberal silences real reports; being too conservative
    under-suppresses, which at worst recreates the v0.1.0 behaviour). *)

let path_suffix_is (p : Path.t) (last_two : string list) : bool =
  match CT.path_to_dotted p with
  | None -> false
  | Some xs ->
      let n = List.length xs and m = List.length last_two in
      n >= m
      &&
      let tail =
        let rec drop k = function
          | xs when k <= 0 -> xs
          | _ :: rest -> drop (k - 1) rest
          | [] -> []
        in
        drop (n - m) xs
      in
      tail = last_two

let is_combinators_failure (p : Path.t) : bool =
  path_suffix_is p [ "Combinators"; "failure" ]

let is_combinators_try_catch (p : Path.t) : bool =
  path_suffix_is p [ "Combinators"; "try_catch" ]

(** Heuristic: strip [make_] prefix and capitalise to recover the tag name a
    PPX-generated [Foo.Errors.make_foo_error] builds. *)
let ppx_make_error_tag (p : Path.t) : string option =
  match p with
  | Path.Pdot (Path.Pdot (_, "Errors"), name)
    when String.length name > 5 && String.sub name 0 5 = "make_" ->
      let bare = String.sub name 5 (String.length name - 5) in
      Some (String.capitalize_ascii bare)
  | _ -> None

let positional_args (args : (Asttypes.arg_label * apply_arg) list) :
    expression list =
  List.filter_map
    (fun (lbl, a) ->
      match (lbl, a) with Asttypes.Nolabel, Arg e -> Some e | _ -> None)
    args

let labeled_arg (args : (Asttypes.arg_label * apply_arg) list) (name : string) :
    expression option =
  List.find_map
    (fun (lbl, a) ->
      match (lbl, a) with
      | Asttypes.Labelled n, Arg e when n = name -> Some e
      | _ -> None)
    args

(** Peel exactly one outer lambda and return the body expression. Used to see
    through [fun _ -> <body>] exception handlers passed to [try_catch]. *)
let peel_one_lambda (e : expression) : expression option =
  match e.exp_desc with
  | Texp_function (_, Tfunction_body b) -> Some b
  | _ -> None

(** Given an [expression] that should already be a [failure]'s direct argument
    (i.e. the error value), return the tag it introduces if we can read it.
    Returns [None] for shapes we don't recognise. *)
let tag_of_failure_arg (e : expression) : string option =
  match e.exp_desc with
  | Texp_variant (lbl, _) -> Some lbl
  | Texp_apply (f, _) -> (
      match ident_path_of f with Some p -> ppx_make_error_tag p | None -> None)
  | _ -> None

(** Scan an expression for recognised body-introducer shapes.

    v0.1.2 P2: in addition to the three direct shapes — literal failure, inline
    try_catch, PPX make_X — this scanner now chases helper calls. When it sees
    an application of a [Texp_ident] whose path resolves through [handler_env]
    to a [Texp_function], it recurses into the helper's body and unions the
    helper's introducers into the outer arm's set.

    The recursion has a depth cap of 5 to bound cost and to defeat mutually
    recursive helpers. When the cap is hit on a path the scanner contributes
    nothing for that path (conservative — accepts a false positive over risking
    infinite loops). The visited set passed by [Hashtbl] also breaks direct
    recursion within the cap. *)
let scan_body_introducers ?(env : handler_env option) (body : expression) :
    string list =
  let acc = ref [] in
  let add t = if not (List.mem t !acc) then acc := t :: !acc in
  let visited : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  let base_env =
    match env with
    | Some e -> e
    | None -> { locals = []; globals = empty_globals () }
  in
  let rec handle_apply
      ~(env : handler_env)
      ~(depth : int)
      (f : expression)
      (args : (Asttypes.arg_label * apply_arg) list) =
    match ident_path_of f with
    | None -> ()
    | Some p ->
        if is_combinators_failure p then
          match positional_args args with
          | a :: _ -> (
              match tag_of_failure_arg a with Some t -> add t | None -> ())
          | [] -> ()
        else if is_combinators_try_catch p then
          match positional_args args with
          | _ :: exn_handler :: _ -> (
              match peel_one_lambda exn_handler with
              | Some b -> (
                  match b.exp_desc with
                  | Texp_variant (lbl, _) -> add lbl
                  | Texp_apply (f', _) -> (
                      match ident_path_of f' with
                      | Some p' -> (
                          match ppx_make_error_tag p' with
                          | Some t -> add t
                          | None -> ())
                      | None -> ())
                  | _ -> ())
              | None -> ())
          | _ -> ()
        else
          (* v0.1.2 P2: chase a helper call. Resolve the path through
             [env] (which may contain locally-introduced [Texp_let] bindings
             from enclosing scopes), recurse into its body. *)
          let key =
            match canonical_key_of_path p with
            | Some k -> k
            | None -> Path.name p
          in
          if Hashtbl.mem visited key then ()
          else if depth <= 0 then ()
          else begin
            Hashtbl.add visited key ();
            match resolve_to_function env depth f with
            | None -> ()
            | Some fn ->
                let rec body_of e =
                  match e.exp_desc with
                  | Texp_function (_, Tfunction_body b) -> body_of b
                  | Texp_function (_, Tfunction_cases _) -> e
                  | _ -> e
                in
                scan_in ~env ~depth:(depth - 1) (body_of fn)
          end
  and scan_in ~(env : handler_env) ~(depth : int) (e : expression) =
    match e.exp_desc with
    | Texp_let (_, vbs, body) ->
        let extra =
          List.filter_map
            (fun vb ->
              match vb.vb_pat.pat_desc with
              | Tpat_var (id, _, _) -> Some (id, vb.vb_expr)
              | _ -> None)
            vbs
        in
        let env' = { env with locals = extra @ env.locals } in
        List.iter (fun vb -> scan_in ~env:env' ~depth vb.vb_expr) vbs;
        scan_in ~env:env' ~depth body
    | Texp_apply (f, args) ->
        handle_apply ~env ~depth f args;
        List.iter
          (fun (_, a) ->
            match a with Arg e -> scan_in ~env ~depth e | _ -> ())
          args
    | _ ->
        let sub_envs : handler_env ref = ref env in
        let it =
          {
            Tast_iterator.default_iterator with
            expr =
              (fun sub e ->
                match e.exp_desc with
                | Texp_let _ -> scan_in ~env:!sub_envs ~depth e
                | Texp_apply (f, args) ->
                    handle_apply ~env:!sub_envs ~depth f args;
                    Tast_iterator.default_iterator.expr sub e
                | _ -> Tast_iterator.default_iterator.expr sub e);
          }
        in
        it.expr it e
  in
  scan_in ~env:base_env ~depth:5 body;
  List.sort compare !acc

(** {1 Arm classification} *)

let classify_services_arm (body : expression) : arm_action * string list =
  match body.exp_desc with
  | Texp_apply (f, _) -> (
      match ident_path_of f with
      | Some p ->
          let n = Path.name p in
          let has_suf suf =
            let ls = String.length n and lu = String.length suf in
            ls >= lu && String.sub n (ls - lu) lu = suf
          in
          (* [.need] / bare [need] is the only Forward shape on services
             arms; anything else (including [.give]) is Discharge by
             default per §2.3. *)
          if has_suf ".need" || n = "need" then (Forward, [])
          else (Discharge, [])
      | None -> (Discharge, []))
  | _ -> (Discharge, [])

let classify_catch_arm ~(env : handler_env) (body : expression) :
    arm_action * string list =
  (* Errors row. v0.1.0 always returned [(Forward, [])]; v0.1.1 now computes
     [body_introduces] via [scan_body_introducers] (§2.3.b). v0.1.2 P2: the
     scanner now follows helper calls through [env]. The action is still
     [Forward] by default — the stale-forwarding-arm rule (§2.3.a) only fires
     when the arm's *pattern tag* also appears in [grew], and the rule already
     suppresses that when the tag is accounted for by some arm's
     [body_introduces]. *)
  (Forward, scan_body_introducers ~env body)

let classify_map_error_arm ~(env : handler_env) (body : expression) :
    arm_action * string list =
  match body.exp_desc with
  | Texp_variant (label, _) -> (Forward, [ label ])
  | _ -> (Discharge, scan_body_introducers ~env body)

let classify_for_kind ~(env : handler_env) (kind : combinator_kind) =
  match kind with
  | Combinators_provide | Layer_provide | Layer_provide_layer
  | Layer_provide_all | Tag_provide _ ->
      classify_services_arm
  | Combinators_catch | Layer_catch -> classify_catch_arm ~env
  | Combinators_map_error -> classify_map_error_arm ~env

let arms_of_cases
    ~(env : handler_env)
    (kind : combinator_kind)
    (cases : value case list) : arm list * bool =
  let wildcard_forward = ref false in
  let classify = classify_for_kind ~env kind in
  let arms =
    List.concat_map
      (fun c ->
        let action, body_introduces = classify c.c_rhs in
        match pattern_tags c.c_lhs with
        | Pwildcard ->
            if action = Forward then wildcard_forward := true;
            []
        | Ptags tags ->
            (* §2.3.b calculus: a "legitimate body introducer" must be a tag
               *not* already matched by this arm's pattern. If the body
               literally re-raises one of the pattern tags, that is exactly
               the stale-forward shape (§2.3.a), not a legitimate introducer.
               So subtract pattern tags from body_introduces before emitting.
            *)
            let body_introduces =
              List.filter (fun t -> not (List.mem t tags)) body_introduces
            in
            List.map
              (fun tag ->
                {
                  tag;
                  action;
                  body_introduces;
                  loc = Compat.loc_of_location c.c_lhs.pat_loc;
                })
              tags)
      cases
  in
  (arms, !wildcard_forward)

(** {1 Argument location and lambda peeling} *)

(** Peel [n] leading [fun _ ->] lambdas and return the inner [Tfunction_cases].
    [n=0] means no peel. *)
let rec peel_n_lambdas (n : int) (e : expression) : value case list option =
  if n <= 0 then
    match e.exp_desc with
    | Texp_function (_, Tfunction_cases { cases; _ }) -> Some cases
    | Texp_function (_, Tfunction_body b) -> peel_n_lambdas 0 b
    | _ -> None
  else
    match e.exp_desc with
    | Texp_function (_params, Tfunction_body b) -> peel_n_lambdas (n - 1) b
    | Texp_function (params, Tfunction_cases _) when List.length params > 0 ->
        peel_n_lambdas 0 e
    | _ -> None

(** Locate the handler expression described by [handler_locator]. *)
let locate_handler
    (args : (Asttypes.arg_label * apply_arg) list)
    (h : CT.handler_locator) : (expression * int) option =
  match h with
  | CT.Positional i -> (
      let ps = positional_args args in
      match List.nth_opt ps i with Some e -> Some (e, 0) | None -> None)
  | CT.Labelled (name, peel) -> (
      match labeled_arg args name with Some e -> Some (e, peel) | None -> None)

let locate_subject (args : (Asttypes.arg_label * apply_arg) list) (idx : int) :
    expression option =
  List.nth_opt (positional_args args) idx

(** {1 Enclosing function tracking for latent-site detection} *)

let rec collect_param_names (params : function_param list) : string list =
  List.concat_map
    (fun p ->
      match p.fp_kind with
      | Tparam_pat pat -> (
          match pat.pat_desc with
          | Tpat_var (id, _, _) -> [ Ident.name id ]
          | Tpat_alias (_, id, _, _, _) -> [ Ident.name id ]
          | _ -> [])
      | _ -> [])
    params

and collect_param_names_deep (e : expression) : string list =
  match e.exp_desc with
  | Texp_function (params, Tfunction_body inner) ->
      collect_param_names params @ collect_param_names_deep inner
  | Texp_function (params, Tfunction_cases _) -> collect_param_names params
  | _ -> []

(** Per-cmt alias map: [let name = <Texp_ident Combinators.provide>] introduces
    [name -> entry]. Independent from [handler_env] because alias entries are
    combinator-table rows, not handler [Texp_function] bodies. *)
type aliases = (string * CT.entry) list

type ctx = {
  enclosing : string option;
      (** Canonical dotted path of the enclosing function, e.g.
          ["Hamlet_lint_fixture_wrapper_stale.p"]. v0.1.2 changed this from a
          bare local name to the full canonical path so that cross-module
          wrapper joins (§Priority 1) match by full identity instead of by last
          path component. *)
  param_names : string list;
  aliases : aliases;
  handlers : handler_env;
}

(** {1 Main per-application dispatch} *)

type emitted = E_concrete of concrete_site | E_latent of latent_site

let handler_site_of_apply
    (ctx : ctx)
    (call_loc : Location.t)
    (apply_type : Types.type_expr)
    (f : expression)
    (args : (Asttypes.arg_label * apply_arg) list) : emitted option =
  match ident_path_of f with
  | None -> None
  | Some path -> (
      let direct = CT.match_combinator path in
      let via_alias =
        match direct with
        | Some _ -> direct
        | None -> (
            match path with
            | Path.Pident id -> List.assoc_opt (Ident.name id) ctx.aliases
            | _ -> None)
      in
      match via_alias with
      | None -> None
      | Some entry
        when match entry.CT.kind with Tag_provide _ -> true | _ -> false ->
          None
      | Some entry -> (
          match
            ( locate_subject args entry.CT.subject_locator,
              locate_handler args entry.CT.handler )
          with
          | None, _ | _, None -> None
          | Some subject, Some (handler, peel) -> (
              (* Priority 5: if the handler isn't directly a [function], try
                 to chase [Texp_ident] references (same-module locals,
                 nested [let] bodies, cross-module Pdot) down to a
                 [Texp_function]. Only apply the chase when the immediate
                 [handler] isn't already something [peel_n_lambdas] can
                 consume — that preserves v0.1.0 behaviour for inline
                 cases and keeps [peel] semantics intact for curried
                 Layer handlers. *)
              let handler_for_peel =
                match peel_n_lambdas peel handler with
                | Some _ -> handler
                | None -> (
                    match resolve_to_function ctx.handlers 5 handler with
                    | Some e' -> e'
                    | None -> handler)
              in
              match peel_n_lambdas peel handler_for_peel with
              | None ->
                  (if Sys.getenv_opt "HAMLET_LINT_DEBUG" <> None then
                     let l = Compat.loc_of_location call_loc in
                     Printf.eprintf
                       "hamlet-lint-extract: skipping non-inline handler for \
                        %s at %s:%d:%d (handler could not be resolved to a \
                        Texp_function within depth 5 — v0.1.1 limitation, see \
                        README §12)\n"
                       (combinator_kind_to_string entry.CT.kind)
                       l.file l.line l.col);
                  None
              | Some cases -> (
                  let arms, has_wildcard_forward =
                    arms_of_cases ~env:ctx.handlers entry.CT.kind cases
                  in
                  let errors_in_lb, services_in_lb =
                    Compat.effect_type_row_lbs subject.exp_type
                  in
                  let errors_out_lb, services_out_lb =
                    Compat.effect_type_row_lbs apply_type
                  in
                  let handler_rec = { has_wildcard_forward; arms } in
                  let mk_row in_lb out_lb =
                    Some
                      {
                        in_lower_bound = in_lb;
                        out_lower_bound = Option.value out_lb ~default:[];
                        handler = handler_rec;
                      }
                  in
                  let services, errors =
                    match entry.CT.row with
                    | Services -> (mk_row services_in_lb services_out_lb, None)
                    | Errors -> (None, mk_row errors_in_lb errors_out_lb)
                  in
                  let subject_is_param =
                    match (strip_one_apply subject).exp_desc with
                    | Texp_ident (Path.Pident id, _, _) ->
                        List.mem (Ident.name id) ctx.param_names
                    | _ -> false
                  in
                  let latent =
                    if subject_is_param then ctx.enclosing else None
                  in
                  let loc = Compat.loc_of_location call_loc in
                  let clear_in r =
                    match r with
                    | None -> None
                    | Some row -> Some { row with in_lower_bound = None }
                  in
                  match latent with
                  | Some fname ->
                      Some
                        (E_latent
                           {
                             loc;
                             kind = entry.CT.kind;
                             latent_in_function = fname;
                             services = clear_in services;
                             errors = clear_in errors;
                           })
                  | None ->
                      Some
                        (E_concrete
                           { loc; kind = entry.CT.kind; services; errors })))))

(** {1 Top-level structure walk} *)

type walk_result = {
  concrete : concrete_site list;
  latent : latent_site list;
  calls : call_site list;
}

(** Walk an expression. Maintains a dynamic [extra_locals] env extension as it
    descends through [Texp_let] so that arm bodies appearing inside an enclosing
    [let raise_bar = ... in ...] see [raise_bar] in their handler env when the
    body-introducer scanner chases a helper call (v0.1.2 P2). *)
let walk_expr (ctx : ctx) (e0 : expression) :
    concrete_site list * latent_site list =
  let concretes = ref [] in
  let latents = ref [] in
  let rec walk (ctx : ctx) (e : expression) =
    match e.exp_desc with
    | Texp_let (_, vbs, body) ->
        let extra =
          List.filter_map
            (fun vb ->
              match vb.vb_pat.pat_desc with
              | Tpat_var (id, _, _) -> Some (id, vb.vb_expr)
              | _ -> None)
            vbs
        in
        let ctx' =
          {
            ctx with
            handlers =
              { ctx.handlers with locals = extra @ ctx.handlers.locals };
          }
        in
        List.iter (fun vb -> walk ctx' vb.vb_expr) vbs;
        walk ctx' body
    | Texp_apply (f, args) ->
        (match handler_site_of_apply ctx e.exp_loc e.exp_type f args with
        | Some (E_concrete s) -> concretes := s :: !concretes
        | Some (E_latent s) -> latents := s :: !latents
        | None -> ());
        walk ctx f;
        List.iter
          (fun (_, a) -> match a with Arg e -> walk ctx e | _ -> ())
          args
    | _ ->
        let it =
          {
            Tast_iterator.default_iterator with
            expr =
              (fun _sub e ->
                match e.exp_desc with
                | Texp_let _ | Texp_apply _ -> walk ctx e
                | _ -> Tast_iterator.default_iterator.expr _sub e);
          }
        in
        it.expr it e
  in
  walk ctx e0;
  (List.rev !concretes, List.rev !latents)

(** Extract the name of a [let name = ...] binding if it's a simple variable
    pattern, else None. *)
let binding_name (vb : value_binding) : string option =
  match vb.vb_pat.pat_desc with
  | Tpat_var (id, _, _) -> Some (Ident.name id)
  | _ -> None

let binding_ident (vb : value_binding) : Ident.t option =
  match vb.vb_pat.pat_desc with Tpat_var (id, _, _) -> Some id | _ -> None

(** Canonicalise the called path of an application to a full dotted key so that
    latent-wrapper join uses identity matching instead of last-component
    matching.

    - A [Pident "f"] is a same-module reference; we prepend the current cmt's
      [modpath] to get e.g. ["Foo.bar"].
    - A [Pdot(Pident "M__N", "f")] is cross-module; [CT.path_to_dotted] already
      canonicalises the dune-mangled prefix.
    - Anything not representable as a dotted path returns [None]. *)
let canonical_called_key ~(modpath : string list) (p : Path.t) : string option =
  match p with
  | Path.Pident id -> Some (String.concat "." (modpath @ [ Ident.name id ]))
  | _ -> (
      match CT.path_to_dotted p with
      | Some xs -> Some (String.concat "." xs)
      | None -> None)

(** Walk the structure visiting top-level [let] bindings, tracking the param
    names of the enclosing named function so we can suppress emitting a
    [call_site] when the call's argument is itself a parameter of that function.
    Such a call is the trigger for the P3 fixed-point promotion of the enclosing
    function — emitting a concrete call_site for it would falsely treat the
    enclosing wrapper's parameter as having empty row lower bounds. *)
let scan_call_sites
    ~(modpath : string list)
    (str : structure)
    (latent_keys : string list) : call_site list =
  let acc = ref [] in
  let in_set key = List.mem key latent_keys in
  let scan_in ~(param_names : string list) (root : expression) =
    let it =
      {
        Tast_iterator.default_iterator with
        expr =
          (fun sub e ->
            (match e.exp_desc with
            | Texp_apply (f, args) -> (
                match ident_path_of f with
                | Some p -> (
                    match canonical_called_key ~modpath p with
                    | None -> ()
                    | Some key -> (
                        if in_set key then
                          match positional_args args with
                          | arg :: _ ->
                              let arg_is_param =
                                match (strip_one_apply arg).exp_desc with
                                | Texp_ident (Path.Pident id, _, _) ->
                                    List.mem (Ident.name id) param_names
                                | _ -> false
                              in
                              if arg_is_param then ()
                              else
                                let err_lb, svc_lb =
                                  Compat.effect_type_row_lbs arg.exp_type
                                in
                                acc :=
                                  {
                                    function_path = key;
                                    loc = Compat.loc_of_location e.exp_loc;
                                    arg_loc = Compat.loc_of_location arg.exp_loc;
                                    arg_services_lb = svc_lb;
                                    arg_errors_lb = err_lb;
                                  }
                                  :: !acc
                          | [] -> ()))
                | None -> ())
            | _ -> ());
            Tast_iterator.default_iterator.expr sub e);
      }
    in
    it.expr it root
  in
  let rec walk_item (item : structure_item) =
    match item.str_desc with
    | Tstr_value (_, vbs) ->
        List.iter
          (fun vb ->
            let pnames =
              match vb.vb_expr.exp_desc with
              | Texp_function _ -> collect_param_names_deep vb.vb_expr
              | _ -> []
            in
            scan_in ~param_names:pnames vb.vb_expr)
          vbs
    | Tstr_module mb -> (
        match mb.mb_expr.mod_desc with
        | Tmod_structure inner -> List.iter walk_item inner.str_items
        | _ -> ())
    | _ ->
        let it =
          {
            Tast_iterator.default_iterator with
            expr = (fun _sub e -> scan_in ~param_names:[] e);
          }
        in
        it.structure_item it item
  in
  List.iter walk_item str.str_items;
  List.rev !acc

let collect_aliases (str : structure) : aliases =
  let acc = ref [] in
  List.iter
    (fun item ->
      match item.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              match (binding_name vb, vb.vb_expr.exp_desc) with
              | Some n, Texp_ident (p, _, _) -> (
                  match CT.match_combinator p with
                  | Some entry -> acc := (n, entry) :: !acc
                  | None -> ())
              | _ -> ())
            vbs
      | _ -> ())
    str.str_items;
  !acc

(** Collect every top-level [let name = <expr>] binding of the structure into a
    [local_env], keyed by [Ident.t]. Used by the walker to chase same-module
    [Pident] handler references. *)
let collect_local_env (str : structure) : local_env =
  let acc = ref [] in
  List.iter
    (fun item ->
      match item.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              match binding_ident vb with
              | Some id -> acc := (id, vb.vb_expr) :: !acc
              | None -> ())
            vbs
      | _ -> ())
    str.str_items;
  !acc

(** Build global entries from a structure for a given [cmt_modname]. The
    resulting keys are [<split_modname>.<binder>] joined with ".". Only bindings
    whose RHS resolves to a [Texp_function] (within depth 5, using this
    structure's own locals) are stored. *)
let collect_global_bindings
    ~(modname : string)
    (str : structure)
    (globals : global_env) : unit =
  let modpath = Compat.split_mangled modname in
  let locals = collect_local_env str in
  (* A placeholder empty globals ref is fine during pre-scan: a binding whose
     alias chain crosses into another module can be resolved on demand during
     the main walk phase by [resolve_to_function]. For pre-scan we only index
     bindings that are directly a [Texp_function] or reduce to one using the
     current module's own locals. *)
  let env = { locals; globals } in
  List.iter
    (fun item ->
      match item.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              match binding_name vb with
              | None -> ()
              | Some name -> (
                  match resolve_to_function env 5 vb.vb_expr with
                  | None -> ()
                  | Some fn ->
                      let key = String.concat "." (modpath @ [ name ]) in
                      Hashtbl.replace globals key fn))
            vbs
      | _ -> ())
    str.str_items

(** Iterate over a typed structure, emitting [concrete_site], [latent_site] and
    [call_site] records. Takes an already-populated [global_env] built from
    every cmt in the load set, plus the cmt's [modname] used to canonicalise
    enclosing-function paths for cross-module wrapper joins (v0.1.2 P1).

    [extra_latent_keys] is the set of canonical paths of functions promoted to
    latent status by the load-set-wide fixed-point iteration (v0.1.2 P3). The
    walker uses this set when emitting [call_site] records so that calls to
    multi-level wrappers join correctly. *)
let walk_structure
    ?(globals : global_env option)
    ?(modname : string = "")
    ?(extra_latent_keys : string list = [])
    (str : structure) : walk_result =
  let globals = match globals with Some g -> g | None -> empty_globals () in
  let modpath = Compat.split_mangled modname in
  let concretes = ref [] in
  let latents = ref [] in
  let aliases = collect_aliases str in
  let locals = collect_local_env str in
  let handlers = { locals; globals } in
  let canonical_of name = String.concat "." (modpath @ [ name ]) in
  let rec walk_item (item : structure_item) =
    match item.str_desc with
    | Tstr_value (_, vbs) ->
        List.iter
          (fun vb ->
            let name = binding_name vb in
            let ctx =
              match (name, vb.vb_expr.exp_desc) with
              | Some n, Texp_function _ ->
                  let pnames = collect_param_names_deep vb.vb_expr in
                  {
                    enclosing = Some (canonical_of n);
                    param_names = pnames;
                    aliases;
                    handlers;
                  }
              | _ -> { enclosing = None; param_names = []; aliases; handlers }
            in
            let cs, ls = walk_expr ctx vb.vb_expr in
            concretes := cs @ !concretes;
            latents := ls @ !latents)
          vbs
    | Tstr_module mb -> (
        match mb.mb_expr.mod_desc with
        | Tmod_structure inner -> List.iter walk_item inner.str_items
        | _ -> ())
    | _ ->
        let ctx = { enclosing = None; param_names = []; aliases; handlers } in
        let it =
          {
            Tast_iterator.default_iterator with
            expr =
              (fun sub e ->
                (match e.exp_desc with
                | Texp_apply (f, args) -> (
                    match
                      handler_site_of_apply ctx e.exp_loc e.exp_type f args
                    with
                    | Some (E_concrete s) -> concretes := s :: !concretes
                    | Some (E_latent s) -> latents := s :: !latents
                    | None -> ())
                | _ -> ());
                Tast_iterator.default_iterator.expr sub e);
          }
        in
        it.structure_item it item
  in
  List.iter walk_item str.str_items;
  let concretes = List.rev !concretes in
  let latents = List.rev !latents in
  let local_latent_keys =
    List.sort_uniq compare
      (List.map (fun (l : latent_site) -> l.latent_in_function) latents)
  in
  let all_latent_keys =
    List.sort_uniq compare (local_latent_keys @ extra_latent_keys)
  in
  let calls =
    if all_latent_keys = [] then []
    else scan_call_sites ~modpath str all_latent_keys
  in
  { concrete = concretes; latent = latents; calls }

(** {1 Multi-level wrapper promotion scan (v0.1.2 P3)}

    Given a global latent-key → exemplar [latent_site] map, scan a structure for
    top-level functions [p] that call some [q] (whose canonical key is in the
    map) with an argument that is a [Pident] bound to a parameter of [p]. Such
    [p] becomes a new latent wrapper inheriting [q]'s row shape; the location of
    the synthesized [latent_site] is the inner [q arg] call inside [p]'s body,
    and the [latent_in_function] is [p]'s canonical key. *)

(** A snapshot of the load-set's known latent sites, keyed by canonical function
    path. Stored as a hashtable for O(1) lookup during each fixed-point pass. *)
type latent_table = (string, latent_site) Hashtbl.t

let latent_table_of_list (ls : latent_site list) : latent_table =
  let h = Hashtbl.create 16 in
  List.iter
    (fun (l : latent_site) ->
      (* If two latent sites share a canonical key (e.g. same wrapper found
         twice), keep the first; the analyzer joins by key, not by record. *)
      if not (Hashtbl.mem h l.latent_in_function) then
        Hashtbl.add h l.latent_in_function l)
    ls;
  h

(** One pass of the fixed-point. Walks [str] looking for top-level functions
    whose body contains an application [q arg] where [q] is in [table] and [arg]
    is a [Pident] referring to a parameter of the enclosing function. Returns a
    list of new [latent_site] records to promote.

    A function already in [table] (under its canonical key built from [modname])
    is skipped — it cannot be re-promoted. *)
let promote_pass ~(modname : string) (table : latent_table) (str : structure) :
    latent_site list =
  let modpath = Compat.split_mangled modname in
  let canonical_of name = String.concat "." (modpath @ [ name ]) in
  let acc = ref [] in
  let scan_function ~(fname : string) (body : expression) =
    let canonical = canonical_of fname in
    if Hashtbl.mem table canonical then ()
    else
      let pnames = collect_param_names_deep body in
      let it =
        {
          Tast_iterator.default_iterator with
          expr =
            (fun sub e ->
              (match e.exp_desc with
              | Texp_apply (f, args) -> (
                  match ident_path_of f with
                  | None -> ()
                  | Some p -> (
                      match canonical_called_key ~modpath p with
                      | None -> ()
                      | Some key -> (
                          match Hashtbl.find_opt table key with
                          | None -> ()
                          | Some exemplar -> (
                              (* The first positional argument must be a
                                 [Pident] referring to a parameter of [fname].
                                 If yes, [fname] inherits [exemplar]'s row
                                 shape and is promoted. *)
                              match positional_args args with
                              | arg :: _ -> (
                                  match (strip_one_apply arg).exp_desc with
                                  | Texp_ident (Path.Pident id, _, _)
                                    when List.mem (Ident.name id) pnames ->
                                      let synth : latent_site =
                                        {
                                          loc = Compat.loc_of_location e.exp_loc;
                                          kind = exemplar.kind;
                                          latent_in_function = canonical;
                                          services = exemplar.services;
                                          errors = exemplar.errors;
                                        }
                                      in
                                      acc := synth :: !acc
                                  | _ -> ())
                              | [] -> ()))))
              | _ -> ());
              Tast_iterator.default_iterator.expr sub e);
        }
      in
      it.expr it body
  in
  let rec walk_item (item : structure_item) =
    match item.str_desc with
    | Tstr_value (_, vbs) ->
        List.iter
          (fun vb ->
            match (binding_name vb, vb.vb_expr.exp_desc) with
            | Some n, Texp_function _ -> scan_function ~fname:n vb.vb_expr
            | _ -> ())
          vbs
    | Tstr_module mb -> (
        match mb.mb_expr.mod_desc with
        | Tmod_structure inner -> List.iter walk_item inner.str_items
        | _ -> ())
    | _ -> ()
  in
  List.iter walk_item str.str_items;
  List.rev !acc
