(** Typedtree walker.

    For every [Texp_apply] whose callee classifies as [`Catch] / [`Provide], try
    to extract the handler's declared tag universe and upstream's effect row.
    When both are recognised, emit a {!Hamlet_lint_schema.Schema.candidate}
    record carrying the two tag lists; the analyzer applies the rule (declared
    \\ upstream ≠ ∅) on the other side of the wire.

    The walker does {b not} apply the rule itself: keeping the decision in the
    analyzer means rule changes never need a re-walk and the wire stays a
    faithful data dump. *)

open Typedtree
module S = Hamlet_lint_schema.Schema

(** Pull out the unlabeled (positional) first argument — upstream effect. *)
let extract_upstream args =
  List.find_map
    (fun (lbl, a) ->
      match (lbl, a) with Asttypes.Nolabel, Arg e -> Some e | _ -> None)
    args

(** Pull out the labeled handler. Both [~f] and [~h] are accepted because
    Hamlet's combinator surface uses both labels in different places. *)
let extract_handler args =
  List.find_map
    (fun (lbl, a) ->
      match (lbl, a) with
      | Asttypes.Labelled ("f" | "h"), Arg e -> Some e
      | _ -> None)
    args

(** Convert [Location.t] → wire-friendly {!S.loc}. The PoC used
    [pos_cnum - pos_bol] for the column; we mirror it for output parity. *)
let loc_to_schema (l : Location.t) : S.loc =
  let p = l.loc_start in
  { file = p.pos_fname; line = p.pos_lnum; col = p.pos_cnum - p.pos_bol }

(** Try to build a candidate for one application. [None] when either side could
    not be recognised — e.g. handler is a literal closure we don't
    pattern-match, or upstream is not a [Hamlet.t] / [Layer.t] value. [~peel] is
    the number of outer handler parameters to skip (used for curried handlers in
    [Layer.provide_to_*]). [~combinator] is the dotted-path name of the callee
    for inclusion in the wire record (e.g. ["catch"], ["map_error"],
    ["Layer.provide_to_effect"]). *)
let try_candidate ~kind ~peel ~combinator ~loc args : S.candidate option =
  match (extract_upstream args, extract_handler args) with
  | Some up, Some h -> (
      match (Handler.universe_tags ~peel h, Upstream.row_tags up ~kind) with
      | Some declared, Some upstream ->
          let site_kind : S.kind =
            match kind with `Catch -> Catch | `Provide -> Provide
          in
          Some
            {
              loc = loc_to_schema loc;
              kind = site_kind;
              combinator;
              declared;
              upstream;
            }
      | _ -> None)
  | _ -> None

(** Strip the [Hamlet.] / [Hamlet__] prefix from a path so the report can show a
    short, user-readable combinator name. ["Hamlet.Layer.provide_to_effect"]
    becomes ["Layer.provide_to_effect"]; ["Hamlet.Combinators.catch"] becomes
    ["catch"]; anything that doesn't start with a Hamlet root is returned
    unchanged. *)
let short_name (path : Path.t) : string =
  let n = Path.name path in
  let strip prefix =
    let pl = String.length prefix in
    if String.length n >= pl && String.sub n 0 pl = prefix then
      String.sub n pl (String.length n - pl)
    else n
  in
  let after_root = strip "Hamlet." in
  if after_root = n then strip "Hamlet__"
  else
    let combinators_prefix = "Combinators." in
    let cl = String.length combinators_prefix in
    if
      String.length after_root >= cl
      && String.sub after_root 0 cl = combinators_prefix
    then String.sub after_root cl (String.length after_root - cl)
    else after_root

(** Walk one [.cmt] file, accumulating candidates. Skips non-impl cmts
    (interfaces have no expressions to inspect). *)
let walk_cmt (path : string) (acc : S.candidate list ref) : unit =
  let cmt = Cmt_format.read_cmt path in
  match cmt.cmt_annots with
  | Implementation str ->
      let check_expr self (e : expression) =
        (match e.exp_desc with
        | Texp_apply (fn, args) -> (
            match fn.exp_desc with
            | Texp_ident (pth, _, vd) -> (
                let combinator = short_name pth in
                let push kind peel =
                  match
                    try_candidate ~kind ~peel ~combinator ~loc:e.exp_loc args
                  with
                  | Some c -> acc := c :: !acc
                  | None -> ()
                in
                match Classify.classify_path pth vd.val_type with
                | Single kind -> push kind 0
                | Curried kind -> push kind 1
                | Other -> ())
            | _ -> ())
        | _ -> ());
        Tast_iterator.default_iterator.expr self e
      in
      let iter = { Tast_iterator.default_iterator with expr = check_expr } in
      iter.structure iter str
  | _ -> ()
