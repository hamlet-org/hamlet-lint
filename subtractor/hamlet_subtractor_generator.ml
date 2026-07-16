open Ppxlib
open Hamlet_subtractor_core
module A = Ast_builder.Default

type error =
  | Missing_catalogue of Identity.t
  | Conflicting_catalogue of Identity.t
  | Invalid_materialization of Leaf.t

type forwarding = Default | Layer_fail_like of string

let error_message = function
  | Missing_catalogue identity ->
      Printf.sprintf
        "missing verified Errors.Cases catalogue for %s; use an explicit \
         [%%hamlet.te ...] boundary"
        (Identity.to_string identity)
  | Conflicting_catalogue identity ->
      Printf.sprintf
        "conflicting Errors.Cases catalogue evidence for %s; rebuild the \
         dependency or use an explicit [%%hamlet.te ...] boundary"
        (Identity.to_string identity)
  | Invalid_materialization leaf ->
      Printf.sprintf
        "the residual leaf %s has no safe source-level propagation pattern"
        (Identity.to_string (Leaf.identity leaf))

let longident = function
  | [] -> invalid_arg "Hamlet_subtractor_generator.longident"
  | [ name ] -> Longident.Lident name
  | head :: tail ->
      List.fold_left
        (fun path name -> Longident.Ldot (path, name))
        (Longident.Lident head) tail

let identity_lid identity =
  longident
    (Identity.module_path identity @ [ Identity.declaration_name identity ])

let module_lid identity = longident (Identity.module_path identity)

let ghost loc = { loc with Location.loc_ghost = true }

let alias ~loc pattern name =
  let nested_loc = ghost loc in
  A.ppat_alias ~loc pattern { txt = name; loc = nested_loc }

let named_pattern ~loc identity name =
  let nested_loc = ghost loc in
  alias ~loc
    (A.ppat_type ~loc:nested_loc
       { txt = identity_lid identity; loc = nested_loc })
    name

let structural_pattern ~loc atom name =
  let nested_loc = ghost loc in
  let argument =
    match Atom.payload atom with
    | Atom.No_payload -> None
    | Atom.Payload _ -> Some (A.ppat_any ~loc:nested_loc)
  in
  alias ~loc (A.ppat_variant ~loc:nested_loc (Atom.label atom) argument) name

let forwarding_rhs ~loc forwarding = function
  | Kind.Error ->
      let callee, arguments =
        match forwarding with
        | Default ->
            ( A.pexp_ident ~loc
                {
                  txt =
                    Longident.Ldot
                      ( Longident.Ldot (Longident.Lident "Hamlet", "Combinators"),
                        "fail" );
                  loc;
                },
              [ (Nolabel, A.evar ~loc "error") ] )
        | Layer_fail_like primary ->
            ( A.pexp_ident ~loc
                {
                  txt =
                    Longident.Ldot
                      ( Longident.Ldot (Longident.Lident "Hamlet", "Layer"),
                        "fail_like" );
                  loc;
                },
              [ (Nolabel, A.evar ~loc primary); (Nolabel, A.evar ~loc "error") ]
            )
      in
      A.pexp_apply ~loc callee arguments
  | Kind.Requirement ->
      A.pexp_apply ~loc
        (A.pexp_ident ~loc
           {
             txt =
               Longident.Ldot
                 (Longident.Ldot (Longident.Lident "Hamlet", "Dispatch"), "need");
             loc;
           })
        [ (Nolabel, A.evar ~loc "witness") ]

let direct_case ~loc ~forwarding leaf =
  let kind = Leaf.kind leaf in
  let name =
    match kind with Kind.Error -> "error" | Requirement -> "witness"
  in
  let lhs = named_pattern ~loc (Leaf.identity leaf) name in
  A.case ~lhs ~guard:None ~rhs:(forwarding_rhs ~loc:(ghost loc) forwarding kind)

let structural_case ~loc ~forwarding leaf atom =
  let kind = Leaf.kind leaf in
  let name =
    match kind with Kind.Error -> "error" | Requirement -> "witness"
  in
  let lhs = structural_pattern ~loc atom name in
  A.case ~lhs ~guard:None ~rhs:(forwarding_rhs ~loc:(ghost loc) forwarding kind)

let warning_attribute ~loc value =
  A.attribute ~loc ~name:{ txt = "warning"; loc }
    ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc value) [] ])

let find_catalogue catalogues identity =
  List.filter
    (fun catalogue ->
      Identity.equal identity (Hamlet_subtractor_catalogue.identity catalogue))
    catalogues

let catalogue_for_leaf catalogues leaf =
  match Leaf.materialization leaf with
  | Leaf.Error_cases { catalogue; union; field } -> (
      match find_catalogue catalogues catalogue with
      | [] -> Error (Missing_catalogue catalogue)
      | evidence :: duplicates
        when List.for_all
               (Hamlet_subtractor_catalogue.equal evidence)
               duplicates
             && Identity.equal union
                  (Hamlet_subtractor_catalogue.union evidence)
             && List.exists
                  (fun (entry : Hamlet_subtractor_catalogue.field) ->
                    Identity.equal entry.leaf (Leaf.identity leaf)
                    && String.equal entry.name field)
                  (Hamlet_subtractor_catalogue.fields evidence) ->
          Ok evidence
      | _ -> Error (Conflicting_catalogue catalogue))
  | _ -> Error (Invalid_materialization leaf)

let same_identity_set left right =
  let sort = List.sort_uniq Identity.compare in
  let left = sort left and right = sort right in
  List.length left = List.length right
  && List.for_all2 Identity.equal left right

let input_case_leaves residual catalogue =
  Residual.input residual
  |> Proof.leaves
  |> List.filter (fun leaf ->
      match Leaf.materialization leaf with
      | Leaf.Error_cases { catalogue = identity; union; _ } ->
          Identity.equal identity
            (Hamlet_subtractor_catalogue.identity catalogue)
          && Identity.equal union (Hamlet_subtractor_catalogue.union catalogue)
      | _ -> false)

let is_full_partition residual catalogue =
  let input = input_case_leaves residual catalogue in
  let input_identities = List.map Leaf.identity input in
  let catalogue_identities =
    Hamlet_subtractor_catalogue.fields catalogue
    |> List.map (fun (field : Hamlet_subtractor_catalogue.field) -> field.leaf)
  in
  same_identity_set input_identities catalogue_identities

let full_case_catalogues ~catalogues residual =
  let candidates =
    Residual.input residual
    |> Proof.leaves
    |> List.filter (fun leaf ->
        match Leaf.materialization leaf with
        | Leaf.Error_cases _ -> true
        | _ -> false)
  in
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | leaf :: rest -> (
        match catalogue_for_leaf catalogues leaf with
        | Error _ as error -> error
        | Ok catalogue ->
            let already_present =
              List.exists
                (fun current ->
                  Identity.equal
                    (Hamlet_subtractor_catalogue.identity current)
                    (Hamlet_subtractor_catalogue.identity catalogue))
                accumulated
            in
            if already_present || not (is_full_partition residual catalogue)
            then loop accumulated rest
            else loop (catalogue :: accumulated) rest)
  in
  loop [] candidates

let residual_contains residual identity =
  Residual.residual residual
  |> List.exists (fun leaf -> Identity.equal identity (Leaf.identity leaf))

let cases_module catalogue =
  module_lid (Hamlet_subtractor_catalogue.identity catalogue)

let cases_function ~loc catalogue name =
  A.pexp_ident ~loc { txt = Longident.Ldot (cases_module catalogue, name); loc }

let unreachable ~loc =
  A.pexp_fun ~loc Nolabel None (A.ppat_any ~loc) [%expr assert false]

let forwarding_callback ~loc forwarding =
  A.pexp_fun ~loc Nolabel None
    (A.ppat_var ~loc { txt = "error"; loc })
    (forwarding_rhs ~loc forwarding Kind.Error)

let cases_record ~loc ~forwarding residual catalogue =
  let propagate =
    A.pexp_apply ~loc
      (cases_function ~loc catalogue "propagate")
      [ (Nolabel, A.eunit ~loc) ]
  in
  let missing =
    Hamlet_subtractor_catalogue.fields catalogue
    |> List.filter (fun (field : Hamlet_subtractor_catalogue.field) ->
        not (residual_contains residual field.leaf))
  in
  match forwarding with
  | Default ->
      begin match missing with
      | [] -> propagate
      | _ ->
          let fields =
            List.map
              (fun (field : Hamlet_subtractor_catalogue.field) ->
                ( {
                    txt = Longident.Ldot (cases_module catalogue, field.name);
                    loc;
                  },
                  unreachable ~loc ))
              missing
          in
          let record = A.pexp_record ~loc fields (Some propagate) in
          { record with pexp_attributes = [ warning_attribute ~loc "-23" ] }
      end
  | Layer_fail_like _ ->
      let fields =
        List.map
          (fun (field : Hamlet_subtractor_catalogue.field) ->
            let rhs =
              if residual_contains residual field.leaf then
                forwarding_callback ~loc forwarding
              else unreachable ~loc
            in
            ( { txt = Longident.Ldot (cases_module catalogue, field.name); loc },
              rhs ))
          (Hamlet_subtractor_catalogue.fields catalogue)
      in
      let record = A.pexp_record ~loc fields None in
      { record with pexp_attributes = [ warning_attribute ~loc "-23" ] }

let cases_dispatch ~loc ~forwarding residual catalogue =
  let nested_loc = ghost loc in
  let union = Hamlet_subtractor_catalogue.union catalogue in
  let lhs = named_pattern ~loc union "error" in
  let rhs =
    A.pexp_apply ~loc:nested_loc
      (cases_function ~loc:nested_loc catalogue "dispatch")
      [
        (Nolabel, cases_record ~loc:nested_loc ~forwarding residual catalogue);
        (Nolabel, A.evar ~loc:nested_loc "error");
      ]
  in
  A.case ~lhs ~guard:None ~rhs

let exhausted_case ~loc =
  let nested_loc = ghost loc in
  A.case ~lhs:(A.ppat_any ~loc) ~guard:None
    ~rhs:(A.pexp_assert ~loc:nested_loc (A.ebool ~loc:nested_loc false))

let refutation_case ~loc =
  let nested_loc = ghost loc in
  A.case
    ~lhs:(A.ppat_any ~loc:nested_loc)
    ~guard:None
    ~rhs:(A.pexp_unreachable ~loc:nested_loc)

let generate_leaf ~loc ~forwarding leaf =
  match Leaf.materialization leaf with
  | Leaf.Direct | Leaf.Requirement_tag | Leaf.Error_cases _ ->
      Ok (direct_case ~loc ~forwarding leaf)
  | Leaf.Structural_variant -> (
      match Leaf.members leaf with
      | [ atom ] -> Ok (structural_case ~loc ~forwarding leaf atom)
      | _ -> Error (Invalid_materialization leaf))
  | Leaf.Unavailable _ -> Error (Invalid_materialization leaf)

let cases ~loc ~catalogues ?(forwarding = Default) residual =
  let residual_leaves = Residual.residual residual in
  match residual_leaves with
  | [] -> Ok [ refutation_case ~loc; exhausted_case ~loc ]
  | _ -> (
      match
        match forwarding with
        | Default -> full_case_catalogues ~catalogues residual
        | Layer_fail_like _ -> Ok []
      with
      | Error _ as error -> error
      | Ok full_catalogues ->
          let generated_cases =
            List.map (cases_dispatch ~loc ~forwarding residual) full_catalogues
          in
          let belongs_to_full_catalogue leaf =
            match Leaf.materialization leaf with
            | Leaf.Error_cases { catalogue; _ } ->
                List.exists
                  (fun current ->
                    Identity.equal catalogue
                      (Hamlet_subtractor_catalogue.identity current))
                  full_catalogues
            | _ -> false
          in
          let leaves =
            residual_leaves
            |> List.filter (fun leaf -> not (belongs_to_full_catalogue leaf))
          in
          let rec loop generated = function
            | [] -> Ok (List.rev generated)
            | leaf :: rest -> (
                match generate_leaf ~loc ~forwarding leaf with
                | Error _ as error -> error
                | Ok case -> loop (case :: generated) rest)
          in
          begin match loop [] leaves with
          | Error _ as error -> error
          | Ok direct_cases ->
              Ok (generated_cases @ direct_cases @ [ refutation_case ~loc ])
          end)
