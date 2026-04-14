(** Pretty reporter. The only reporter implemented in v0.1 (the design doc also
    specs GitHub Actions and SARIF; both are M7, out of scope). *)

open Rule
open Hamlet_lint_schema.Schema

let pp_loc (l : loc) = Printf.sprintf "%s:%d:%d" l.file l.line l.col

let pretty (findings : finding list) : string =
  let buf = Buffer.create 256 in
  List.iter
    (fun (f : Rule.finding) ->
      Buffer.add_string buf (pp_loc f.loc);
      Buffer.add_string buf ": ";
      Buffer.add_string buf f.message;
      Buffer.add_char buf '\n';
      Buffer.add_string buf "  arm at ";
      Buffer.add_string buf (pp_loc f.arm_loc);
      Buffer.add_char buf '\n')
    findings;
  if findings = [] then Buffer.add_string buf "no findings\n";
  Buffer.contents buf
