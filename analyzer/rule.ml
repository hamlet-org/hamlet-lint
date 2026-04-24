(** Retroactive widening rule.

    Given a candidate {!Hamlet_lint_schema.Schema.candidate}, the rule is the
    list-set difference [declared \\ upstream]. When the difference is non-empty
    the candidate becomes a finding: the handler advertises tags upstream's row
    never carries.

    OCaml's row subtyping cannot reject this at compile time (covariant ['e] /
    ['r] design), hence the post-compile check. *)

module S = Hamlet_lint_schema.Schema

type finding = {
  loc : S.loc;
  kind : S.kind;
  combinator : string;
  declared : string list;
  upstream : string list;
  extra : string list;
      (** Tags in [declared] absent from [upstream]. Always non-empty for a
          finding. *)
}

(** Apply the rule to a single candidate. *)
let check (c : S.candidate) : finding option =
  let extra =
    List.filter (fun tag -> not (List.mem tag c.upstream)) c.declared
  in
  if extra = [] then None
  else
    Some
      {
        loc = c.loc;
        kind = c.kind;
        combinator = c.combinator;
        declared = c.declared;
        upstream = c.upstream;
        extra;
      }

(** Apply the rule across an ND-JSON record stream. Headers are skipped.
    Findings appear in input order. *)
let analyze (records : S.record list) : finding list =
  List.filter_map
    (function S.Header _ -> None | S.Candidate c -> check c)
    records
