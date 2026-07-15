open Ast_helper
open Asttypes
open Longident
open Parsetree

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.equal prefix (String.sub value 0 prefix_length)

let bound_name pattern =
  match pattern.ppat_desc with
  | Ppat_var { txt; _ } -> Some txt
  | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, _) -> Some txt
  | _ -> None

let normalized_match ~loc cases =
  Exp.match_ ~loc (Exp.ident ~loc { loc; txt = Lident "__input" }) cases

let collect_matches expression =
  let matches = ref [] in
  let iterator =
    {
      Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.pexp_desc with
          | Pexp_match (_, cases) ->
              matches :=
                normalized_match ~loc:expression.pexp_loc cases :: !matches
          | Pexp_function (params, _, Pfunction_cases (cases, _, _))
            when params = [] ->
              matches :=
                normalized_match ~loc:expression.pexp_loc cases :: !matches
          | _ -> ());
          Ast_iterator.default_iterator.expr self expression);
    }
  in
  iterator.expr iterator expression;
  List.rev !matches

let parse filename =
  let channel = open_in_bin filename in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let lexbuf = Lexing.from_channel channel in
      Location.init lexbuf filename;
      Parse.implementation lexbuf)

let first_dump = ref true

let dump_binding binding =
  match bound_name binding.pvb_pat with
  | Some name when has_prefix ~prefix:"case_" name ->
      collect_matches binding.pvb_expr
      |> List.iteri (fun index expression ->
          if !first_dump then first_dump := false else Format.printf "@.";
          Format.printf "%s match-%d:@.%a@." name (index + 1)
            Pprintast.expression expression)
  | _ -> ()

let () =
  if Array.length Sys.argv <> 2 then
    invalid_arg "usage: automatic_propagation_expansion_dump PREPROCESSED_ML";
  parse Sys.argv.(1)
  |> List.iter (fun item ->
      match item.pstr_desc with
      | Pstr_value (_, bindings) -> List.iter dump_binding bindings
      | _ -> ())
