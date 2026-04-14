(** Implementation of the rule described in [docs/RULE.md] §2.

    Pure OCaml, no compiler-libs. Takes fully-populated schema records produced
    by [hamlet-lint-extract] and emits a list of findings. *)

open Hamlet_lint_schema.Schema

type finding = {
  loc : loc;
  combinator : combinator_kind;
  row : row_name;
  tag : string;
  arm_loc : loc;
  message : string;
}

(* [row_name_to_string] lives in [Schema] alongside [combinator_kind_to_string]
   so both wire-to-human translation tables are in one module. *)

let diff a b = List.filter (fun x -> not (List.mem x b)) a

(** Core row check: §2.3 of the spec.

    [in_lb] is the effective input lower bound (for a concrete site: the row's
    [in_lower_bound]; for a latent site joined against a call: the arg's row-lb
    at that call).

    Returns one finding per phantom tag attributable to a stale Forward arm.
    Stays silent for tags attributable to a legitimate body introducer (§2.3.b)
    or for tags the walker cannot attribute to any arm (§2.3.c). *)
let check_row
    ~(loc : loc)
    ~(combinator : combinator_kind)
    ~(row_name : row_name)
    ~(in_lb : string list)
    (row : row) : finding list =
  if row.handler.has_wildcard_forward then []
  else
    let grew = diff row.out_lower_bound in_lb in
    List.filter_map
      (fun tag ->
        (* §2.3.b: legitimate body introducer — some arm's inferred 'e
           lower bound contains the tag. Only meaningful for errors row. *)
        let legitimate_via_body =
          List.exists
            (fun arm -> List.mem tag arm.body_introduces)
            row.handler.arms
        in
        if legitimate_via_body then None
        else
          (* §2.3.a: stale Forward arm — the arm pattern matches this tag
             and its action is Forward. *)
          match
            List.find_opt
              (fun (arm : Hamlet_lint_schema.Schema.arm) ->
                arm.tag = tag && arm.action = Forward)
              row.handler.arms
          with
          | Some arm ->
              let kind_s = combinator_kind_to_string combinator in
              let row_s = row_name_to_string row_name in
              let msg =
                Printf.sprintf
                  "stale forwarding arm for tag `%s in %s row: input effect \
                   has no such dependency, this arm resurrects it (%s)"
                  tag row_s kind_s
              in
              Some
                {
                  loc;
                  combinator;
                  row = row_name;
                  tag;
                  arm_loc = arm.loc;
                  message = msg;
                }
          (* §2.3.c: unattributable — silent. *)
          | None -> None)
      grew

(** Shared row-optional dispatch for both concrete and latent-join paths. The
    caller supplies the effective [in_lb] because the two sites derive it
    differently: concrete reads it off the row itself, latent joins pull it from
    the outer call's argument lower bounds. *)
let check_row_opt ~loc ~kind ~row_name ~in_lb = function
  | None -> []
  | Some (row : row) -> check_row ~loc ~combinator:kind ~row_name ~in_lb row

(** Run the rule on one concrete site: check both populated row records. *)
let check_concrete (s : concrete_site) : finding list =
  let in_lb_of = function
    | None -> []
    | Some (row : row) -> Option.value row.in_lower_bound ~default:[]
  in
  check_row_opt ~loc:s.loc ~kind:s.kind ~row_name:Services
    ~in_lb:(in_lb_of s.services) s.services
  @ check_row_opt ~loc:s.loc ~kind:s.kind ~row_name:Errors
      ~in_lb:(in_lb_of s.errors) s.errors

(** Run the rule on a latent site joined against a matching call site. The
    finding lands at the outer call site's location, with the in_lb read off the
    arg's row-lb at that call. *)
let check_latent_join (lat : latent_site) (call : call_site) : finding list =
  let lb = Option.value ~default:[] in
  check_row_opt ~loc:call.loc ~kind:lat.kind ~row_name:Services
    ~in_lb:(lb call.arg_services_lb) lat.services
  @ check_row_opt ~loc:call.loc ~kind:lat.kind ~row_name:Errors
      ~in_lb:(lb call.arg_errors_lb) lat.errors

(** Full analyzer pipeline: iterate concrete sites, then join latent sites
    against call sites. Latent sites with zero call sites produce nothing
    (unused wrapper, no bug yet — §2.6). *)
let analyze (records : record list) : finding list =
  let concretes =
    List.filter_map (function Concrete s -> Some s | _ -> None) records
  in
  let latents =
    List.filter_map (function Latent s -> Some s | _ -> None) records
  in
  let calls =
    List.filter_map (function Call c -> Some c | _ -> None) records
  in
  let from_concrete = List.concat_map check_concrete concretes in
  let from_latent =
    List.concat_map
      (fun lat ->
        let matches =
          List.filter (fun c -> c.function_path = lat.latent_in_function) calls
        in
        List.concat_map (fun call -> check_latent_join lat call) matches)
      latents
  in
  from_concrete @ from_latent
