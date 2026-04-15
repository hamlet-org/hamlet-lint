(** Walker base helpers: small, pure functions shared across the walker's
    sibling modules ({!Handler_env}, {!Arm_classify}, {!Latent_fixpoint}, and
    the umbrella {!Walker}). No Hamlet-specific logic lives here; only Typedtree
    shape manipulation. *)

open Typedtree
module CT = Combinator_table

(** Peel one outer application layer. Used when a caller wants to see past an
    optional trailing argument: [wrap arg extra] should compare structurally as
    [wrap arg] against a parameter ident. Central helper so the three sites that
    do this (handler-site classification, call-site scan, promote pass) stay in
    sync. *)
let strip_one_apply (e : expression) : expression =
  match e.exp_desc with Texp_apply (inner, _) -> inner | _ -> e

(** Strip a single [Texp_ident] from an application and return its [Path.t]. *)
let ident_path_of (e : expression) : Path.t option =
  match e.exp_desc with Texp_ident (p, _, _) -> Some p | _ -> None

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

(** Extract the name of a [let name = ...] binding if it's a simple variable
    pattern, else [None]. *)
let binding_name (vb : value_binding) : string option =
  match vb.vb_pat.pat_desc with
  | Tpat_var (id, _, _) -> Some (Ident.name id)
  | _ -> None

let binding_ident (vb : value_binding) : Ident.t option =
  match vb.vb_pat.pat_desc with Tpat_var (id, _, _) -> Some id | _ -> None
