(** Multi-level wrapper promotion scan (fixed-point phase).

    Given a global latent-key → exemplar [latent_site] map, scan a structure for
    top-level functions [p] that call some [q] (whose canonical key is in the
    map) with an argument that is a [Pident] bound to a parameter of [p]. Such
    [p] becomes a new latent wrapper inheriting [q]'s row shape; the location of
    the synthesised [latent_site] is the inner [q arg] call inside [p]'s body,
    and the [latent_in_function] is [p]'s canonical key.

    Iteration termination is monotone: entries are only added, never removed.
    The driver in [extract/pipeline.ml] caps passes at [|fns_in_load_set| + 10]
    as a safety valve. *)

open Typedtree
open Hamlet_lint_schema.Schema
module WU = Walker_util

(** A snapshot of the load-set's known latent sites, keyed by canonical function
    path. Stored as a hashtable for O(1) lookup during each fixed-point pass. *)
type table = (string, latent_site) Hashtbl.t

let table_of_list (ls : latent_site list) : table =
  let h = Hashtbl.create 16 in
  List.iter
    (fun (l : latent_site) ->
      (* If two latent sites share a canonical key (e.g. same wrapper found
         twice), keep the first: the analyzer joins by key, not by record. *)
      if not (Hashtbl.mem h l.latent_in_function) then
        Hashtbl.add h l.latent_in_function l)
    ls;
  h

(** One pass of the fixed-point. Walks [str] looking for top-level functions
    whose body contains an application [q arg] where [q] is in [table] and [arg]
    is a [Pident] referring to a parameter of the enclosing function. Returns a
    list of new [latent_site] records to promote.

    A function already in [table] (under its canonical key built from [modname])
    is skipped: it cannot be re-promoted. *)
let promote_pass ~(modname : string) (table : table) (str : structure) :
    latent_site list =
  let modpath = Compat.split_mangled modname in
  let canonical_of name = String.concat "." (modpath @ [ name ]) in
  let acc = ref [] in
  let scan_function ~(fname : string) (body : expression) =
    let canonical = canonical_of fname in
    if Hashtbl.mem table canonical then ()
    else
      let pnames = WU.collect_param_names_deep body in
      let it =
        {
          Tast_iterator.default_iterator with
          expr =
            (fun sub e ->
              (match e.exp_desc with
              | Texp_apply (f, args) -> (
                  match WU.ident_path_of f with
                  | None -> ()
                  | Some p -> (
                      match WU.canonical_called_key ~modpath p with
                      | None -> ()
                      | Some key -> (
                          match Hashtbl.find_opt table key with
                          | None -> ()
                          | Some exemplar -> (
                              (* The first positional argument must be a
                                 [Pident] referring to a parameter of [fname].
                                 If yes, [fname] inherits [exemplar]'s row
                                 shape and is promoted. *)
                              match WU.positional_args args with
                              | arg :: _ -> (
                                  match (WU.strip_one_apply arg).exp_desc with
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
            match (WU.binding_name vb, vb.vb_expr.exp_desc) with
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
