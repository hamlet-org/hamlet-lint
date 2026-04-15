(** Arm classification and body-introducer scanning.

    For each handler case (arm) of a recognised combinator, decide whether the
    arm is a [Forward] (re-raises the matched tag) or a [Discharge] (consumes
    it), and compute its [body_introduces] set — the error tags the arm body
    legitimately produces via a recognised introducer shape. These two outputs
    feed the rule in [analyzer/rule.ml] §2.3.

    Recognised introducer shapes for [body_introduces]:

    - [Combinators.failure (`Tag)]: direct literal variant.
    - [Combinators.failure (Foo.Errors.make_<n> ...)]: PPX constructor,
      heuristically mapped to a tag by strip-prefix-and-capitalise.
    - [Combinators.try_catch f (fun _ -> `Tag)]: inline exn handler returning a
      direct literal variant.
    - Transitive helper calls: an application whose [Texp_ident] resolves
      through {!Handler_env} to a [Texp_function], unioning that helper's own
      introducers into the outer arm. Capped at depth 5 with a visited set. *)

open Typedtree
open Hamlet_lint_schema.Schema
module CT = Combinator_table
module WU = Walker_util

(** Collect the (poly-variant) head tag names from a pattern. Handles
    [Tpat_variant], [Tpat_alias] (peels the alias), and [Tpat_or] (unions both
    sides). Returns [`Wildcard] if the pattern is [Tpat_any] or [Tpat_var]:
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
      match WU.ident_path_of f with
      | Some p -> ppx_make_error_tag p
      | None -> None)
  | _ -> None

(** Scan an expression for recognised body-introducer shapes. See the module
    docstring for the shape list. The scanner chases helper calls through
    {!Handler_env} with a depth cap of 5 and a visited set, so mutually
    recursive helpers terminate. *)
let scan_body_introducers ?(env : Handler_env.t option) (body : expression) :
    string list =
  let acc = ref [] in
  let add t = if not (List.mem t !acc) then acc := t :: !acc in
  let visited : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  let base_env : Handler_env.t =
    match env with
    | Some e -> e
    | None -> { locals = []; globals = Handler_env.empty_globals () }
  in
  let rec handle_apply
      ~(env : Handler_env.t)
      ~(depth : int)
      (f : expression)
      (args : (Asttypes.arg_label * apply_arg) list) =
    match WU.ident_path_of f with
    | None -> ()
    | Some p ->
        if is_combinators_failure p then
          match WU.positional_args args with
          | a :: _ -> (
              match tag_of_failure_arg a with Some t -> add t | None -> ())
          | [] -> ()
        else if is_combinators_try_catch p then
          match WU.positional_args args with
          | _ :: exn_handler :: _ -> (
              match peel_one_lambda exn_handler with
              | Some b -> (
                  match b.exp_desc with
                  | Texp_variant (lbl, _) -> add lbl
                  | Texp_apply (f', _) -> (
                      match WU.ident_path_of f' with
                      | Some p' -> (
                          match ppx_make_error_tag p' with
                          | Some t -> add t
                          | None -> ())
                      | None -> ())
                  | _ -> ())
              | None -> ())
          | _ -> ()
        else
          (* Chase a helper call: resolve the path through [env] (which may
             contain locally-introduced [Texp_let] bindings from enclosing
             scopes), then recurse into the helper body. *)
          let key =
            match Handler_env.canonical_key_of_path p with
            | Some k -> k
            | None -> Path.name p
          in
          if Hashtbl.mem visited key then ()
          else if depth <= 0 then ()
          else begin
            Hashtbl.add visited key ();
            match Handler_env.resolve_to_function env depth f with
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
  and scan_in ~(env : Handler_env.t) ~(depth : int) (e : expression) =
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
        let sub_envs : Handler_env.t ref = ref env in
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

let classify_services_arm (body : expression) : arm_action * string list =
  match body.exp_desc with
  | Texp_apply (f, _) -> (
      match WU.ident_path_of f with
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

let classify_catch_arm ~(env : Handler_env.t) (body : expression) :
    arm_action * string list =
  (* Errors row. The action is [Forward] by default: the stale-forwarding-arm
     rule (§2.3.a) only fires when the arm's *pattern tag* also appears in
     [grew], and the rule already suppresses that when the tag is accounted
     for by some arm's [body_introduces]. *)
  (Forward, scan_body_introducers ~env body)

let classify_map_error_arm ~(env : Handler_env.t) (body : expression) :
    arm_action * string list =
  match body.exp_desc with
  | Texp_variant (label, _) -> (Forward, [ label ])
  | _ -> (Discharge, scan_body_introducers ~env body)

let classify_for_kind ~(env : Handler_env.t) (kind : combinator_kind) =
  match kind with
  | Combinators_provide | Layer_provide | Layer_provide_layer
  | Layer_provide_all | Tag_provide _ ->
      classify_services_arm
  | Combinators_catch | Layer_catch -> classify_catch_arm ~env
  | Combinators_map_error -> classify_map_error_arm ~env

let arms_of_cases
    ~(env : Handler_env.t)
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
               So subtract pattern tags from body_introduces before emitting. *)
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
