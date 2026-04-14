(** Shared OCaml types for the ND-JSON wire contract between
    [hamlet-lint-extract] and [hamlet-lint].

    Contract shape (ND-JSON, one object per line):
    {v
      {"kind":"header","schema_version":1,"ocaml_version":"5.4.1",...}
      {"kind":"concrete_site", ...}
      {"kind":"latent_site", ...}
      {"kind":"call_site", ...}
    v}

    Rationale for ND-JSON over a single JSON document (deviation from the
    original design doc): streaming friendliness, trivial concatenation of
    per-cmt outputs, simpler incremental parsing, and snapshot tests that can
    diff line-by-line. The first record is always a header carrying
    [schema_version]; the analyzer rejects any other major version. *)

(** Current contract major version. Bump on breaking changes. *)
let schema_version = 1

(** A source location, identical across every record kind. *)
type loc = { file : string; line : int; col : int }

(** The row being analysed. Each handler-style combinator touches exactly one
    row per §2.0 of the spec. *)
type row_name = Services | Errors

(** Arm classification per §2.3 of the spec.

    - [Discharge]: the arm reduces the row (e.g. a [give] body for services, a
      [success _] body for errors).
    - [Forward]: the arm preserves or re-introduces the matched tag (a [need]
      body for services, a [failure tag'] body for errors, a poly-variant
      head-tag echo for [map_error]). *)
type arm_action = Discharge | Forward

type arm = {
  tag : string;  (** Polymorphic variant tag name, without the backtick. *)
  action : arm_action;
  body_introduces : string list;
      (** For errors-row arms only: the lower bound of ['e] of the arm body's
          inferred [exp_type]. Always [[]] for services arms. Used to attribute
          a [grew] tag to a legitimate body introducer (§2.3.b). *)
  loc : loc;
}

type handler = {
  has_wildcard_forward : bool;
      (** True iff some catch-all arm ends in a forwarding action. When true the
          analyzer suppresses every report on this row of this call (§2.7). *)
  arms : arm list;
}

(** A row record attached to a call site. A given call populates only the row
    its combinator touches. *)
type row = {
  in_lower_bound : string list option;  (** [None] only on latent sites. *)
  out_lower_bound : string list;
  handler : handler;
}

(** Which Hamlet combinator this call site is. Only the closed §2.0 set is
    tracked; unknown paths are skipped by the extractor. *)
type combinator_kind =
  | Combinators_provide
  | Combinators_catch
  | Combinators_map_error
  | Layer_provide
  | Layer_provide_layer
  | Layer_provide_all
  | Layer_catch
  | Tag_provide of string  (** module name, e.g. "ConsoleTag" *)

let row_name_to_string = function Services -> "services" | Errors -> "errors"

let combinator_kind_to_string = function
  | Combinators_provide -> "Hamlet.Combinators.provide"
  | Combinators_catch -> "Hamlet.Combinators.catch"
  | Combinators_map_error -> "Hamlet.Combinators.map_error"
  | Layer_provide -> "Hamlet.Layer.provide"
  | Layer_provide_layer -> "Hamlet.Layer.provide_layer"
  | Layer_provide_all -> "Hamlet.Layer.provide_all"
  | Layer_catch -> "Hamlet.Layer.catch"
  | Tag_provide m -> m ^ ".Tag.provide"

let combinator_kind_of_string = function
  | "Hamlet.Combinators.provide" -> Some Combinators_provide
  | "Hamlet.Combinators.catch" -> Some Combinators_catch
  | "Hamlet.Combinators.map_error" -> Some Combinators_map_error
  | "Hamlet.Layer.provide" -> Some Layer_provide
  | "Hamlet.Layer.provide_layer" -> Some Layer_provide_layer
  | "Hamlet.Layer.provide_all" -> Some Layer_provide_all
  | "Hamlet.Layer.catch" -> Some Layer_catch
  | s
    when (* Suffix test against the 12-char literal ".Tag.provide". Prior to
         the fix this compared 13 bytes against a 12-byte literal, so the
         arm never matched and [Tag_provide _] round-tripped as [None]. *)
         let suf = ".Tag.provide" in
         let n = String.length s and k = String.length suf in
         n > k && String.sub s (n - k) k = suf ->
      let k = String.length ".Tag.provide" in
      Some (Tag_provide (String.sub s 0 (String.length s - k)))
  | _ -> None

(** A concrete application site: [in_lb] is known, findings emitted here. *)
type concrete_site = {
  loc : loc;
  kind : combinator_kind;
  services : row option;
  errors : row option;
}

(** A latent application site: [in_lb] is [None] because the input is a free row
    variable parameter of an enclosing function. Must be joined against a
    [call_site] record for the same function path. *)
type latent_site = {
  loc : loc;
  kind : combinator_kind;
  latent_in_function : string;  (** [Path.name] of the enclosing function. *)
  services : row option;
  errors : row option;
}

(** A call to a function that has a latent handler-site inside it. *)
type call_site = {
  function_path : string;
  loc : loc;
  arg_loc : loc;
  arg_services_lb : string list option;
  arg_errors_lb : string list option;
}

type header = {
  schema_version : int;
  ocaml_version : string;
  generated_at : string;
}

type record =
  | Header of header
  | Concrete of concrete_site
  | Latent of latent_site
  | Call of call_site

(** {1 Yojson encoders / decoders} *)

let loc_to_yojson (l : loc) : Yojson.Safe.t =
  `Assoc
    [ ("file", `String l.file); ("line", `Int l.line); ("col", `Int l.col) ]

let loc_of_yojson = function
  | `Assoc fs ->
      let file = match List.assoc "file" fs with `String s -> s | _ -> "" in
      let line = match List.assoc "line" fs with `Int i -> i | _ -> 0 in
      let col = match List.assoc "col" fs with `Int i -> i | _ -> 0 in
      { file; line; col }
  | _ -> failwith "loc_of_yojson: not an object"

let string_list_to_yojson xs : Yojson.Safe.t =
  `List (List.map (fun s -> `String s) xs)

let string_list_of_yojson = function
  | `List xs ->
      List.map (function `String s -> s | _ -> failwith "string_list") xs
  | `Null -> []
  | _ -> failwith "string_list_of_yojson"

let arm_action_to_yojson = function
  | Discharge -> `String "Discharge"
  | Forward -> `String "Forward"

let arm_action_of_yojson = function
  | `String "Discharge" -> Discharge
  | `String "Forward" -> Forward
  | _ -> failwith "arm_action_of_yojson"

let arm_to_yojson (a : arm) : Yojson.Safe.t =
  `Assoc
    [
      ("tag", `String a.tag);
      ("action", arm_action_to_yojson a.action);
      ("body_introduces", string_list_to_yojson a.body_introduces);
      ("loc", loc_to_yojson a.loc);
    ]

let arm_of_yojson = function
  | `Assoc fs ->
      let tag = match List.assoc "tag" fs with `String s -> s | _ -> "" in
      let action = arm_action_of_yojson (List.assoc "action" fs) in
      let body_introduces =
        string_list_of_yojson (List.assoc "body_introduces" fs)
      in
      let loc = loc_of_yojson (List.assoc "loc" fs) in
      { tag; action; body_introduces; loc }
  | _ -> failwith "arm_of_yojson"

let handler_to_yojson (h : handler) : Yojson.Safe.t =
  `Assoc
    [
      ("has_wildcard_forward", `Bool h.has_wildcard_forward);
      ("arms", `List (List.map arm_to_yojson h.arms));
    ]

let handler_of_yojson = function
  | `Assoc fs ->
      let has_wildcard_forward =
        match List.assoc "has_wildcard_forward" fs with
        | `Bool b -> b
        | _ -> false
      in
      let arms =
        match List.assoc "arms" fs with
        | `List xs -> List.map arm_of_yojson xs
        | _ -> []
      in
      { has_wildcard_forward; arms }
  | _ -> failwith "handler_of_yojson"

let row_to_yojson (r : row) : Yojson.Safe.t =
  `Assoc
    [
      ( "in_lower_bound",
        match r.in_lower_bound with
        | None -> `Null
        | Some xs -> string_list_to_yojson xs );
      ("out_lower_bound", string_list_to_yojson r.out_lower_bound);
      ("handler", handler_to_yojson r.handler);
    ]

let row_of_yojson = function
  | `Assoc fs ->
      let in_lower_bound =
        match List.assoc "in_lower_bound" fs with
        | `Null -> None
        | x -> Some (string_list_of_yojson x)
      in
      let out_lower_bound =
        string_list_of_yojson (List.assoc "out_lower_bound" fs)
      in
      let handler = handler_of_yojson (List.assoc "handler" fs) in
      { in_lower_bound; out_lower_bound; handler }
  | `Null -> failwith "row: null"
  | _ -> failwith "row_of_yojson"

let row_opt_to_yojson = function None -> `Null | Some r -> row_to_yojson r

let row_opt_of_yojson = function `Null -> None | j -> Some (row_of_yojson j)

let concrete_to_yojson (s : concrete_site) : Yojson.Safe.t =
  `Assoc
    [
      ("kind", `String "concrete_site");
      ("loc", loc_to_yojson s.loc);
      ("combinator", `String (combinator_kind_to_string s.kind));
      ("services", row_opt_to_yojson s.services);
      ("errors", row_opt_to_yojson s.errors);
    ]

let concrete_of_yojson = function
  | `Assoc fs ->
      let loc = loc_of_yojson (List.assoc "loc" fs) in
      let kind =
        match List.assoc "combinator" fs with
        | `String s -> (
            match combinator_kind_of_string s with
            | Some k -> k
            | None -> failwith ("unknown combinator: " ^ s))
        | _ -> failwith "combinator"
      in
      let services = row_opt_of_yojson (List.assoc "services" fs) in
      let errors = row_opt_of_yojson (List.assoc "errors" fs) in
      { loc; kind; services; errors }
  | _ -> failwith "concrete_of_yojson"

let latent_to_yojson (s : latent_site) : Yojson.Safe.t =
  `Assoc
    [
      ("kind", `String "latent_site");
      ("loc", loc_to_yojson s.loc);
      ("combinator", `String (combinator_kind_to_string s.kind));
      ("latent_in_function", `String s.latent_in_function);
      ("services", row_opt_to_yojson s.services);
      ("errors", row_opt_to_yojson s.errors);
    ]

let latent_of_yojson = function
  | `Assoc fs ->
      let loc = loc_of_yojson (List.assoc "loc" fs) in
      let kind =
        match List.assoc "combinator" fs with
        | `String s -> (
            match combinator_kind_of_string s with
            | Some k -> k
            | None -> failwith ("unknown combinator: " ^ s))
        | _ -> failwith "combinator"
      in
      let latent_in_function =
        match List.assoc "latent_in_function" fs with `String s -> s | _ -> ""
      in
      let services = row_opt_of_yojson (List.assoc "services" fs) in
      let errors = row_opt_of_yojson (List.assoc "errors" fs) in
      { loc; kind; latent_in_function; services; errors }
  | _ -> failwith "latent_of_yojson"

let call_to_yojson (c : call_site) : Yojson.Safe.t =
  let lb_to = function None -> `Null | Some xs -> string_list_to_yojson xs in
  `Assoc
    [
      ("kind", `String "call_site");
      ("function_path", `String c.function_path);
      ("loc", loc_to_yojson c.loc);
      ("arg_loc", loc_to_yojson c.arg_loc);
      ("arg_services_lb", lb_to c.arg_services_lb);
      ("arg_errors_lb", lb_to c.arg_errors_lb);
    ]

let call_of_yojson = function
  | `Assoc fs ->
      let lb_of = function
        | `Null -> None
        | x -> Some (string_list_of_yojson x)
      in
      let function_path =
        match List.assoc "function_path" fs with `String s -> s | _ -> ""
      in
      let loc = loc_of_yojson (List.assoc "loc" fs) in
      let arg_loc = loc_of_yojson (List.assoc "arg_loc" fs) in
      let arg_services_lb = lb_of (List.assoc "arg_services_lb" fs) in
      let arg_errors_lb = lb_of (List.assoc "arg_errors_lb" fs) in
      { function_path; loc; arg_loc; arg_services_lb; arg_errors_lb }
  | _ -> failwith "call_of_yojson"

let header_to_yojson (h : header) : Yojson.Safe.t =
  `Assoc
    [
      ("kind", `String "header");
      ("schema_version", `Int h.schema_version);
      ("ocaml_version", `String h.ocaml_version);
      ("generated_at", `String h.generated_at);
    ]

let header_of_yojson = function
  | `Assoc fs ->
      let schema_version =
        match List.assoc "schema_version" fs with `Int i -> i | _ -> 0
      in
      let ocaml_version =
        match List.assoc "ocaml_version" fs with `String s -> s | _ -> ""
      in
      let generated_at =
        match List.assoc "generated_at" fs with `String s -> s | _ -> ""
      in
      { schema_version; ocaml_version; generated_at }
  | _ -> failwith "header_of_yojson"

let record_to_yojson = function
  | Header h -> header_to_yojson h
  | Concrete s -> concrete_to_yojson s
  | Latent s -> latent_to_yojson s
  | Call c -> call_to_yojson c

let record_of_yojson (j : Yojson.Safe.t) : record =
  match j with
  | `Assoc fs -> (
      match List.assoc "kind" fs with
      | `String "header" -> Header (header_of_yojson j)
      | `String "concrete_site" -> Concrete (concrete_of_yojson j)
      | `String "latent_site" -> Latent (latent_of_yojson j)
      | `String "call_site" -> Call (call_of_yojson j)
      | `String k -> failwith ("unknown record kind: " ^ k)
      | _ -> failwith "record: missing kind")
  | _ -> failwith "record_of_yojson: not an object"

(** Emit a record as a single ND-JSON line (no trailing newline). *)
let record_to_ndjson_line r = Yojson.Safe.to_string (record_to_yojson r)

(** Parse an ND-JSON stream from a channel. Skips blank lines. *)
let read_ndjson (ic : in_channel) : record list =
  let rec loop acc =
    match input_line ic with
    | exception End_of_file -> List.rev acc
    | "" -> loop acc
    | line ->
        let r = record_of_yojson (Yojson.Safe.from_string line) in
        loop (r :: acc)
  in
  loop []
