(** Handler resolution environment.

    Used by {!Arm_classify} and {!Walker} to resolve [Texp_ident] handler
    arguments back to the [Texp_function] body that the walker's arm classifier
    needs. Four reference shapes are supported: same-module [Pident] bindings,
    alias chains, nested [let]-in RHS, cross-module [Pdot] references via a
    pre-built global table. *)

open Typedtree
module CT = Combinator_table

(** Per-module table of top-level (and nested [let]-body) bindings keyed by
    their [Ident.t], so same-module [Pident] references can be chased without
    string matching. *)
type local_env = (Ident.t * expression) list

(** Global table keyed by canonical dotted name (e.g.
    ["Hamlet_lint_fixture_cross_module_handler"; "Handler_mod"; "h"]), joined
    with "." for hashing. Values are the already-resolved [Texp_function]
    expressions of cross-module handler definitions. *)
type global_env = (string, expression) Hashtbl.t

type t = { locals : local_env; globals : global_env }

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
    is reached within [depth] steps. The depth cap of 5 (used by callers) bounds
    alias-chain traversal; see [docs/ARCHITECTURE.md] §6 for the rationale. *)
let rec resolve_to_function (env : t) (depth : int) (e : expression) :
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
