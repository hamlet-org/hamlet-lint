(** Table of recognised Hamlet handler-style combinators, keyed by [Path.t]
    structure rather than by string suffix.

    Each entry describes how to locate the handler and the subject effect in the
    application's argument list, how many leading lambdas to peel before
    reaching the [Tfunction_cases] body, and which row of which type-constructor
    family carries the lower bound that the linter needs to compare.

    This module is the only place in the walker that knows the dotted names of
    Hamlet combinators. Adding a ninth combinator is a one-line change here plus
    a new row-shape entry. *)

open Hamlet_lint_schema.Schema

(** How the handler argument is passed and how many lambdas to peel off the
    front before the actual case list begins. *)
type handler_locator =
  | Positional of int  (** zero-based index among [Nolabel] args; no peel *)
  | Labelled of string * int
      (** labelled arg name, and number of leading [fun _ ->] lambdas to peel (0
          for a bare [function], 1 for curried [fun svc -> function ...]). *)

type entry = {
  kind : combinator_kind;
  subject_locator : int;
      (** zero-based index of the subject arg among [Nolabel] positional args.
          For both effect subjects [('a,'e,'r) Hamlet.t] and layer subjects
          [('svc,'e,'r) Hamlet.Layer.layer] we only need the position — the row
          lookup is uniform across the two shapes. *)
  handler : handler_locator;
  row : row_name;
}

(** Structural comparison of [Path.t]s to a dotted name list. Accepts an
    optional leading [Hamlet__] mangling that ocamlc may introduce for
    dune-wrapped libraries, and strips it transparently. *)
let rec path_to_dotted (p : Path.t) : string list option =
  match p with
  | Pident id ->
      let name = Ident.name id in
      (* Dune's main-module-name wrapper may appear as either [Hamlet] or
         [Hamlet__]; canonicalise by stripping the trailing underscores. *)
      let name =
        let n = String.length name in
        let rec strip i =
          if i > 0 && name.[i - 1] = '_' then strip (i - 1) else i
        in
        let k = strip n in
        if k = 0 then name else String.sub name 0 k
      in
      Some [ name ]
  | Pdot (p, s) -> (
      match path_to_dotted p with Some xs -> Some (xs @ [ s ]) | None -> None)
  | Papply _ | Pextra_ty _ -> None

let matches_dotted (p : Path.t) (expected : string list) : bool =
  match path_to_dotted p with Some xs -> xs = expected | None -> false

(** Entries for the eight spec'd combinators plus the PPX [Tag.provide] special
    case (handled outside the table). *)
let entries : entry list =
  [
    {
      kind = Combinators_provide;
      subject_locator = 1;
      (* provide handler inner — handler is arg 0, inner is arg 1 *)
      handler = Positional 0;
      row = Services;
    };
    {
      kind = Combinators_catch;
      subject_locator = 0;
      handler = Labelled ("f", 0);
      row = Errors;
    };
    {
      kind = Combinators_map_error;
      subject_locator = 0;
      handler = Labelled ("f", 0);
      row = Errors;
    };
    {
      kind = Layer_provide;
      (* [Layer.provide layer ~handler consumer]: positional args are
         [layer; consumer]; subject for row purposes is [consumer]. *)
      subject_locator = 1;
      handler = Labelled ("handler", 1);
      row = Services;
    };
    {
      kind = Layer_provide_layer;
      (* [Layer.provide_layer dep ~handler con]: positional [dep; con];
         subject is [con], a layer. *)
      subject_locator = 1;
      handler = Labelled ("handler", 1);
      row = Services;
    };
    {
      kind = Layer_provide_all;
      (* [Layer.provide_all ~handler ~build consumer]: only one positional
         (consumer). *)
      subject_locator = 0;
      handler = Labelled ("handler", 1);
      row = Services;
    };
    {
      kind = Layer_catch;
      subject_locator = 0;
      handler = Labelled ("f", 0);
      row = Errors;
    };
  ]

(** Map a combinator kind to its fully-qualified dotted spelling. *)
let dotted_for_kind = function
  | Combinators_provide -> Some [ "Hamlet"; "Combinators"; "provide" ]
  | Combinators_catch -> Some [ "Hamlet"; "Combinators"; "catch" ]
  | Combinators_map_error -> Some [ "Hamlet"; "Combinators"; "map_error" ]
  | Layer_provide -> Some [ "Hamlet"; "Layer"; "provide" ]
  | Layer_provide_layer -> Some [ "Hamlet"; "Layer"; "provide_layer" ]
  | Layer_provide_all -> Some [ "Hamlet"; "Layer"; "provide_all" ]
  | Layer_catch -> Some [ "Hamlet"; "Layer"; "catch" ]
  | Tag_provide _ -> None

(** Detect a PPX-generated [<Mod>.Tag.provide]. Any path shaped as
    [Pdot (Pdot (_, "Tag"), "provide")] qualifies; the module prefix is the
    service's user-visible module name and is captured into the [Tag_provide]
    constructor for reporting. *)
let match_tag_provide (p : Path.t) : combinator_kind option =
  match p with
  | Pdot (Pdot (mod_path, "Tag"), "provide") ->
      let mod_name =
        match path_to_dotted mod_path with
        | Some xs -> String.concat "." xs
        | None -> Path.name mod_path
      in
      Some (Tag_provide mod_name)
  | _ -> None

(** Main entry point. Given a [Path.t] resolved from a [Texp_ident], return the
    matching entry if the path denotes one of the eight recognised combinators,
    a PPX [Tag.provide], or [None] otherwise.

    For [Tag.provide] we return a synthetic entry whose shape mirrors
    [Combinators_provide] (one positional handler, one positional inner) — the
    walker uses the same arm extraction logic for both. *)
let match_combinator (p : Path.t) : entry option =
  let found =
    List.find_opt
      (fun e ->
        match dotted_for_kind e.kind with
        | Some d -> matches_dotted p d
        | None -> false)
      entries
  in
  match found with
  | Some _ as r -> r
  | None -> (
      match match_tag_provide p with
      | Some k ->
          Some
            {
              kind = k;
              subject_locator = 1;
              handler = Positional 0;
              row = Services;
            }
      | None -> None)
