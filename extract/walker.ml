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

(** Pull out the unlabeled (positional) first argument — upstream effect.
    Re-exported from {!Upstream.extract_upstream} so the recursive residual
    logic and the walker share one canonical extractor. *)
let extract_upstream = Upstream.extract_upstream

(** Pull out the labeled handler. The label is combinator-specific (e.g. ["f"]
    for [catch], ["handler"] for [provide], ["filter"] for [catch_filter]).
    Re-exported from {!Upstream.extract_handler}. *)
let extract_handler = Upstream.extract_handler

(** Convert [Location.t] → wire-friendly {!S.loc}. The PoC used
    [pos_cnum - pos_bol] for the column; we mirror it for output parity. *)
let loc_to_schema (l : Location.t) : S.loc =
  let p = l.loc_start in
  { file = p.pos_fname; line = p.pos_lnum; col = p.pos_cnum - p.pos_bol }

(** Try to build a candidate for one application. [None] when either side could
    not be recognised — e.g. handler is a literal closure we don't
    pattern-match, or upstream is not a [Hamlet.t] / [Layer.t] value. [~info] is
    the combinator descriptor carrying [slot], [peel], [handler_label], and
    [wraps_in_cause]. [~combinator] is the dotted-path name of the callee for
    inclusion in the wire record (e.g. ["catch"], ["map_error"],
    ["Layer.provide_to_effect"]). *)
let try_candidate ~(info : Classify.info) ~combinator ~loc args :
    S.candidate option =
  match
    (extract_upstream args, extract_handler ~label:info.handler_label args)
  with
  | Some up, Some h -> (
      match
        ( Handler.universe_tags ~peel:info.peel
            ~wraps_in_cause:info.wraps_in_cause h,
          Upstream.row_tags up ~kind:info.slot )
      with
      | Some declared, Some upstream ->
          let site_kind : S.kind =
            match info.slot with `Catch -> Catch | `Provide -> Provide
          in
          (* combinators like [provide_scope] silently introduce a service into
             upstream's row before the handler sees it — the runtime always
             seeds [Scope] on the new frame, regardless of whether upstream's
             [val_type] mentions it. Union those tags into [upstream] so the
             handler's mandatory discharge arm is not flagged as widening. *)
          let upstream =
            List.fold_left
              (fun acc t -> if List.mem t acc then acc else acc @ [ t ])
              upstream info.implicit_upstream_tags
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

(** Second-probe candidate for [catch_filter] / [catch_cause_filter]: compares
    [~f]'s first-parameter declared row against the upper bound inferred from
    [~filter]'s body (every [Some _]'s argument tags). When [~f]'s declaration
    is wider than what [~filter] can actually emit, the extra arms are dead code
    — the same retroactive widening pattern as the primary probe but on
    ['match_] instead of upstream's row. Hard-codes the labels (["filter"] /
    ["f"]) since both monitored filter combinators share them. *)
let try_match_candidate ~combinator ~loc args : S.candidate option =
  match
    (extract_handler ~label:"filter" args, extract_handler ~label:"f" args)
  with
  | Some filter, Some f -> (
      match
        ( Handler.universe_tags ~peel:0 ~wraps_in_cause:false f,
          Filter_output.infer_output_tags filter )
      with
      | Some declared, Some inferred ->
          Some
            {
              loc = loc_to_schema loc;
              kind = Catch;
              combinator;
              declared;
              upstream = inferred;
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

(** Raised by {!walk_cmt} when [Cmt_format.read_cmt] cannot parse [path] —
    corrupt, truncated, or built by an incompatible compiler. The driver in
    [extract/main.ml] catches this and exits 2 with the original message,
    keeping the documented 0/1/2 exit-code discipline. *)
exception Bad_cmt of string * string

(** Walk one [.cmt] file, accumulating candidates. Skips non-impl cmts
    (interfaces have no expressions to inspect). Raises {!Bad_cmt} when
    [Cmt_format.read_cmt] fails — caller is responsible for turning that into a
    controlled user error.

    Catch-all on [Cmt_format.read_cmt] failures: the function chains through
    [Cmt_format.read] → [Cmi_format] → [Magic_numbers], any of which can throw
    its own exception type (including [Magic_numbers.Cmi.Error] for wrong-magic
    files, [Sys_error] for unreadable ones, [End_of_file] for truncated ones,
    [Cmt_format.Error] for non-typedtree payloads). Anything thrown there means
    "this file is not a usable .cmt", so we wrap it uniformly as [Bad_cmt]
    instead of trying to enumerate the exception surface. *)
let walk_cmt (path : string) (acc : S.candidate list ref) : unit =
  let cmt =
    try Cmt_format.read_cmt path
    with e -> raise (Bad_cmt (path, Printexc.to_string e))
  in
  match cmt.cmt_annots with
  | Implementation str ->
      let process_call ~loc ~callee ~args =
        match callee.exp_desc with
        | Texp_ident (pth, _, vd) -> (
            let combinator = short_name pth in
            match Classify.classify_path pth vd.val_type vd with
            | Match info ->
                (match try_candidate ~info ~combinator ~loc args with
                | Some c -> acc := c :: !acc
                | None -> ());
                if info.match_probe then
                  begin match try_match_candidate ~combinator ~loc args with
                  | Some c -> acc := c :: !acc
                  | None -> ()
                  end
            | Other -> ())
        | _ -> ()
      in
      let check_expr self (e : expression) =
        (match e.exp_desc with
        | Texp_apply (fn, args) -> (
            match fn.exp_desc with
            | Texp_ident _ -> process_call ~loc:e.exp_loc ~callee:fn ~args
            | Texp_apply (inner_callee, _) -> (
                (* Pipe form [eff |> catch ~f:H] and other staged
                   partial-then-apply shapes: the inner partial holds the
                   real callee + named args, the outer holds the
                   positional upstream. {!Upstream.unstage_apply}
                   combines them into a canonical full-arg list, after
                   which classification is identical to the direct form.

                   Reports the finding at the inner partial's location
                   (the actual [catch] keyword), not at the outer apply
                   (the start of the chain), so e2e expectations stay
                   precise. *)
                match Upstream.unstage_apply e with
                | Some (real_callee, combined_args) ->
                    process_call ~loc:inner_callee.exp_loc ~callee:real_callee
                      ~args:combined_args
                | None -> ())
            | _ -> ())
        | _ -> ());
        Tast_iterator.default_iterator.expr self e
      in
      let iter = { Tast_iterator.default_iterator with expr = check_expr } in
      iter.structure iter str
  | _ -> ()
