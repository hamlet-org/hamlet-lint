(** Typedtree walker: umbrella.

    This module is the orchestrating driver. The four concerns it dispatches
    over live in siblings and are re-entered directly from here:

    - {!Walker_util}: small pure helpers shared across the walker stack
      (argument peeling, path canonicalisation, param-name collection,
      binding-name extraction).
    - {!Handler_env}: resolution of [Texp_ident] handler arguments down to a
      [Texp_function], supporting same-module bindings, alias chains, nested
      [let]-in, and cross-module [Pdot] via a pre-built global table.
    - {!Arm_classify}: arm pattern/action classification and per-arm
      [body_introduces] scanning for the body-introducer rule (§2.3.b).
    - {!Latent_fixpoint}: multi-level wrapper promotion, iterated from
      {!Extract.Pipeline}'s phase 3 until monotone closure.

    Scope (see [docs/RULE.md] §1 for the combinator list and
    [docs/LIMITATIONS.md] for what is out of scope):

    - All eight combinators from [docs/RULE.md] §1: [Combinators.provide],
      [Combinators.catch], [Combinators.map_error], [Layer.provide],
      [Layer.provide_layer], [Layer.provide_all], [Layer.catch], and the
      PPX-generated [<Mod>.Tag.provide].
    - Latent sites with multi-level chains, mutual recursion, and cross-module
      joining. Reports are deferred to the outer call site via a
      [latent_site]/[call_site] join handled by the analyzer.

    Walker/schema coupling (design note, 3.4). The walker produces
    [Hamlet_lint_schema.Schema] records directly: there are ~80 references to
    [Schema.*] constructors from here and the sibling modules. This is
    deliberate. The schema is the wire contract between [hamlet-lint-extract]
    and [hamlet-lint], and the walker is the only producer, so inserting an
    intermediate "walker IR" plus IR→schema translator would be pure churn. A
    future refactor that proposes such a layer should first answer: what does
    the IR let us express that Schema does not? As of v0.1 the answer is
    "nothing", so the direct coupling stays. *)

open Typedtree
open Hamlet_lint_schema.Schema
module CT = Combinator_table
module WU = Walker_util

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
      let ps = WU.positional_args args in
      match List.nth_opt ps i with Some e -> Some (e, 0) | None -> None)
  | CT.Labelled (name, peel) -> (
      match WU.labeled_arg args name with
      | Some e -> Some (e, peel)
      | None -> None)

let locate_subject (args : (Asttypes.arg_label * apply_arg) list) (idx : int) :
    expression option =
  List.nth_opt (WU.positional_args args) idx

(** Per-cmt alias map: [let name = <Texp_ident Combinators.provide>] introduces
    [name -> entry]. Independent from {!Handler_env} because alias entries are
    combinator-table rows, not handler [Texp_function] bodies. *)
type aliases = (string * CT.entry) list

type ctx = {
  enclosing : string option;
      (** Canonical dotted path of the enclosing function, e.g.
          ["Hamlet_lint_fixture_wrapper_stale.p"]. Full canonical path (not bare
          local name) so that cross-module wrapper joins match by full identity
          instead of last-component. *)
  param_names : string list;
  aliases : aliases;
  handlers : Handler_env.t;
}

type emitted = E_concrete of concrete_site | E_latent of latent_site

let handler_site_of_apply
    (ctx : ctx)
    (call_loc : Location.t)
    (apply_type : Types.type_expr)
    (f : expression)
    (args : (Asttypes.arg_label * apply_arg) list) : emitted option =
  match WU.ident_path_of f with
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
              (* If the handler isn't directly a [function], chase [Texp_ident]
                 references (same-module locals, nested [let] bodies,
                 cross-module Pdot) down to a [Texp_function]. Only apply the
                 chase when the immediate [handler] isn't already something
                 [peel_n_lambdas] can consume: that preserves inline-case
                 behaviour and keeps [peel] semantics for curried Layer
                 handlers. *)
              let handler_for_peel =
                match peel_n_lambdas peel handler with
                | Some _ -> handler
                | None -> (
                    match
                      Handler_env.resolve_to_function ctx.handlers 5 handler
                    with
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
                        Texp_function within depth 5; see docs/LIMITATIONS.md)\n"
                       (combinator_kind_to_string entry.CT.kind)
                       l.file l.line l.col);
                  None
              | Some cases -> (
                  let arms, has_wildcard_forward =
                    Arm_classify.arms_of_cases ~env:ctx.handlers entry.CT.kind
                      cases
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
                    match (WU.strip_one_apply subject).exp_desc with
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

type walk_result = {
  concrete : concrete_site list;
  latent : latent_site list;
  calls : call_site list;
}

(** Walk an expression. Maintains a dynamic [extra_locals] env extension as it
    descends through [Texp_let] so that arm bodies appearing inside an enclosing
    [let raise_bar = ... in ...] see [raise_bar] in their handler env when the
    body-introducer scanner chases a helper call. *)
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

(** Walk the structure visiting top-level [let] bindings, tracking the param
    names of the enclosing named function so we can suppress emitting a
    [call_site] when the call's argument is itself a parameter of that function.
    Such a call is the trigger for the fixed-point promotion of the enclosing
    function: emitting a concrete call_site for it would falsely treat the
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
                match WU.ident_path_of f with
                | Some p -> (
                    match WU.canonical_called_key ~modpath p with
                    | None -> ()
                    | Some key -> (
                        if in_set key then
                          match WU.positional_args args with
                          | arg :: _ ->
                              let arg_is_param =
                                match (WU.strip_one_apply arg).exp_desc with
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
              | Texp_function _ -> WU.collect_param_names_deep vb.vb_expr
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
              match (WU.binding_name vb, vb.vb_expr.exp_desc) with
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
    [Handler_env.local_env], keyed by [Ident.t]. Used to chase same-module
    [Pident] handler references. *)
let collect_local_env (str : structure) : Handler_env.local_env =
  let acc = ref [] in
  List.iter
    (fun item ->
      match item.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              match WU.binding_ident vb with
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
    (globals : Handler_env.global_env) : unit =
  let modpath = Compat.split_mangled modname in
  let locals = collect_local_env str in
  (* A placeholder empty globals ref is fine during pre-scan: a binding whose
     alias chain crosses into another module can be resolved on demand during
     the main walk phase by [Handler_env.resolve_to_function]. Pre-scan only
     indexes bindings that are directly a [Texp_function] or reduce to one
     using the current module's own locals. *)
  let env : Handler_env.t = { locals; globals } in
  List.iter
    (fun item ->
      match item.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              match WU.binding_name vb with
              | None -> ()
              | Some name -> (
                  match Handler_env.resolve_to_function env 5 vb.vb_expr with
                  | None -> ()
                  | Some fn ->
                      let key = String.concat "." (modpath @ [ name ]) in
                      Hashtbl.replace globals key fn))
            vbs
      | _ -> ())
    str.str_items

(** Iterate over a typed structure, emitting [concrete_site], [latent_site] and
    [call_site] records. Takes an already-populated [Handler_env.global_env]
    built from every cmt in the load set, plus the cmt's [modname] used to
    canonicalise enclosing-function paths for cross-module wrapper joins.

    [extra_latent_keys] is the set of canonical paths of functions promoted to
    latent status by the load-set-wide fixed-point iteration. The walker uses
    this set when emitting [call_site] records so that calls to multi-level
    wrappers join correctly. *)
let walk_structure
    ?(globals : Handler_env.global_env option)
    ?(modname : string = "")
    ?(extra_latent_keys : string list = [])
    (str : structure) : walk_result =
  let globals =
    match globals with Some g -> g | None -> Handler_env.empty_globals ()
  in
  let modpath = Compat.split_mangled modname in
  let concretes = ref [] in
  let latents = ref [] in
  let aliases = collect_aliases str in
  let locals = collect_local_env str in
  let handlers : Handler_env.t = { locals; globals } in
  let canonical_of name = String.concat "." (modpath @ [ name ]) in
  let rec walk_item (item : structure_item) =
    match item.str_desc with
    | Tstr_value (_, vbs) ->
        List.iter
          (fun vb ->
            let name = WU.binding_name vb in
            let ctx =
              match (name, vb.vb_expr.exp_desc) with
              | Some n, Texp_function _ ->
                  let pnames = WU.collect_param_names_deep vb.vb_expr in
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
