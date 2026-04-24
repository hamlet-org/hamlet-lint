(** Pretty-print findings for human consumption. Multi-line; mirrors the format
    used by the upstream PoC ([hamlet/lint_poc/bin/poc.ml]) so that snapshot
    tests carrying over from the PoC don't drift. *)

module S = Hamlet_lint_schema.Schema

let key_of_kind : S.kind -> string = function
  | Catch -> "[%hamlet.te ...]"
  | Provide -> "[%hamlet.ts ...]"

(** Render one finding to a string using the same shape as the PoC: a leading
    file:line:col, then four indented fields. The combinator name (e.g.
    [map_error], [Layer.provide_to_effect]) appears in the WARNING line so
    callers can tell which call site was flagged when multiple combinator
    families coexist in the same source range. *)
let pp_finding (f : Rule.finding) : string =
  Printf.sprintf
    "File %S, line %d, characters %d-%d:\n\
    \  hamlet-lint WARNING: %s handler declares %s tags not present in upstream.\n\
    \    declared  : [%s]\n\
    \    upstream  : [%s]\n\
    \    extra tag%s not emitted : [%s]\n"
    f.loc.file f.loc.line f.loc.col f.loc.col f.combinator (key_of_kind f.kind)
    (String.concat "; " f.declared)
    (String.concat "; " f.upstream)
    (if List.length f.extra = 1 then "" else "s")
    (String.concat "; " f.extra)

let pretty (findings : Rule.finding list) : string =
  String.concat "" (List.map pp_finding findings)
