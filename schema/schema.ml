(** Wire contract between [hamlet-lint-extract] (depends on [compiler-libs],
    walks .cmt files) and [hamlet-lint] (analyzer, agnostic to the OCaml
    internals). One JSON object per line on stdout/stdin.

    The contract is intentionally minimal: the extractor reports
    {b candidate sites} — calls to [Hamlet.Combinators.catch] / [.provide] where
    it managed to extract both the handler's declared tag universe and
    upstream's row tags. The analyzer applies the rule (declared \\ upstream ≠
    ∅) and prints findings.

    {1 Schema versioning}

    The leading record on every stream is a [Header] carrying [schema_version].
    Any breaking change (added/removed required field, kind addition, semantic
    shift in tag interpretation) bumps the version. The analyzer rejects
    mismatched versions with exit code 2 so callers can distinguish "tool bug"
    from "findings present". *)

let schema_version = 1

type loc = { file : string; line : int; col : int }
type kind = Catch | Provide

(** A single recognised call site for one of the 7 monitored combinators. The
    two tag lists are presented in source declaration order; the analyzer
    compares them with a list-set difference. *)
type candidate = {
  loc : loc;
  kind : kind;
  combinator : string;
      (** The dotted path of the actual combinator — e.g. [catch], [map_error],
          [Layer.provide_to_effect]. [kind] only tells you which slot was
          inspected; this field lets the report say precisely which combinator
          fired. *)
  declared : string list;
      (** Handler's declared universe ([%hamlet.te ...] or [%hamlet.ts ...]). *)
  upstream : string list;
      (** Upstream's effect row tags at the relevant slot ([`'e`] for [Catch],
          [`'r`] for [Provide]). *)
}

type header = {
  schema_version : int;
  ocaml_version : string;
      (** [Sys.ocaml_version] of the extractor binary, for diagnostics. *)
  generated_at : string;
      (** Either ["runtime"] or ["canonical"] (sorted-output mode for snapshot
          tests). Free-form, never parsed. *)
}

type record = Header of header | Candidate of candidate

(* ============================================================ *)
(* JSON encoding                                                *)
(* ============================================================ *)

let kind_to_string = function Catch -> "catch" | Provide -> "provide"

let kind_of_string = function
  | "catch" -> Catch
  | "provide" -> Provide
  | s -> failwith (Printf.sprintf "schema: unknown kind %S" s)

let loc_to_yojson (l : loc) : Yojson.Basic.t =
  `Assoc
    [ ("file", `String l.file); ("line", `Int l.line); ("col", `Int l.col) ]

(** [List.assoc] raises [Not_found], which is opaque to callers. Wrap in
    [Failure] so the analyzer's wire-error handler catches every decoding fault
    uniformly. *)
let assoc_or_fail ctx k fs =
  match List.assoc_opt k fs with
  | Some v -> v
  | None -> failwith (Printf.sprintf "%s: missing field %S" ctx k)

let loc_of_yojson (j : Yojson.Basic.t) : loc =
  match j with
  | `Assoc fs ->
      let s k =
        match assoc_or_fail "loc" k fs with
        | `String x -> x
        | _ -> failwith ("loc: " ^ k ^ " not a string")
      in
      let i k =
        match assoc_or_fail "loc" k fs with
        | `Int x -> x
        | _ -> failwith ("loc: " ^ k ^ " not an int")
      in
      { file = s "file"; line = i "line"; col = i "col" }
  | _ -> failwith "loc: expected object"

let strings_of_yojson (j : Yojson.Basic.t) : string list =
  match j with
  | `List xs ->
      List.map
        (function `String s -> s | _ -> failwith "expected string in list")
        xs
  | _ -> failwith "expected JSON array of strings"

let strings_to_yojson (xs : string list) : Yojson.Basic.t =
  `List (List.map (fun s -> `String s) xs)

let candidate_to_yojson (c : candidate) : Yojson.Basic.t =
  `Assoc
    [
      ("kind", `String "candidate");
      ("site_kind", `String (kind_to_string c.kind));
      ("combinator", `String c.combinator);
      ("loc", loc_to_yojson c.loc);
      ("declared", strings_to_yojson c.declared);
      ("upstream", strings_to_yojson c.upstream);
    ]

let candidate_of_yojson_fields fs : candidate =
  let site_kind =
    match assoc_or_fail "candidate" "site_kind" fs with
    | `String s -> kind_of_string s
    | _ -> failwith "candidate: site_kind not a string"
  in
  let combinator =
    match assoc_or_fail "candidate" "combinator" fs with
    | `String s -> s
    | _ -> failwith "candidate: combinator not a string"
  in
  {
    kind = site_kind;
    combinator;
    loc = loc_of_yojson (assoc_or_fail "candidate" "loc" fs);
    declared = strings_of_yojson (assoc_or_fail "candidate" "declared" fs);
    upstream = strings_of_yojson (assoc_or_fail "candidate" "upstream" fs);
  }

let header_to_yojson (h : header) : Yojson.Basic.t =
  `Assoc
    [
      ("kind", `String "header");
      ("schema_version", `Int h.schema_version);
      ("ocaml_version", `String h.ocaml_version);
      ("generated_at", `String h.generated_at);
    ]

let header_of_yojson_fields fs : header =
  let s k =
    match assoc_or_fail "header" k fs with
    | `String x -> x
    | _ -> failwith ("header: " ^ k ^ " not a string")
  in
  let i k =
    match assoc_or_fail "header" k fs with
    | `Int x -> x
    | _ -> failwith ("header: " ^ k ^ " not an int")
  in
  {
    schema_version = i "schema_version";
    ocaml_version = s "ocaml_version";
    generated_at = s "generated_at";
  }

let record_to_yojson : record -> Yojson.Basic.t = function
  | Header h -> header_to_yojson h
  | Candidate c -> candidate_to_yojson c

let record_of_yojson : Yojson.Basic.t -> record = function
  | `Assoc fs -> (
      match List.assoc_opt "kind" fs with
      | Some (`String "header") -> Header (header_of_yojson_fields fs)
      | Some (`String "candidate") -> Candidate (candidate_of_yojson_fields fs)
      | Some (`String s) -> failwith ("record: unknown kind " ^ s)
      | _ -> failwith "record: missing kind field")
  | _ -> failwith "record: expected object"

let record_to_ndjson_line (r : record) : string =
  Yojson.Basic.to_string (record_to_yojson r)

(** Read a stream of ND-JSON records from [ic]. Stops at EOF. Blank lines are
    skipped; malformed lines abort with [Failure]. *)
let read_ndjson (ic : in_channel) : record list =
  let rec loop acc =
    match input_line ic with
    | exception End_of_file -> List.rev acc
    | line ->
        let trimmed = String.trim line in
        if trimmed = "" then loop acc
        else
          let r = record_of_yojson (Yojson.Basic.from_string trimmed) in
          loop (r :: acc)
  in
  loop []
