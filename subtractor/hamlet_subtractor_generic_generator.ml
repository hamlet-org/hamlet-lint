open Ppxlib
open Hamlet_subtractor_core
module A = Ast_builder.Default

type error = Hamlet_subtractor_generator.error

let longident = function
  | [] -> invalid_arg "Hamlet_subtractor_generic_generator.longident"
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
  A.ppat_alias ~loc pattern { txt = name; loc = ghost loc }

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

let is_claimed claimed leaf =
  List.exists
    (fun candidate ->
      Identity.equal (Leaf.identity candidate) (Leaf.identity leaf)
      ||
      match (Leaf.materialization candidate, Leaf.materialization leaf) with
      | Leaf.Structural_variant, Leaf.Structural_variant ->
          let candidate_members = Leaf.members candidate in
          let leaf_members = Leaf.members leaf in
          List.length candidate_members = List.length leaf_members
          && List.for_all
               (fun member ->
                 List.exists (Atom.equal_structural member) leaf_members)
               candidate_members
      | _ -> false)
    claimed

let callback ~loc ~claimed name =
  A.pexp_apply ~loc
    (A.evar ~loc (if claimed then "handled" else "forward"))
    [ (Nolabel, A.evar ~loc name) ]

let warning_attribute ~loc value =
  A.attribute ~loc ~name:{ txt = "warning"; loc }
    ~payload:(PStr [ A.pstr_eval ~loc (A.estring ~loc value) [] ])

let direct_case ~loc ~claimed leaf =
  let name =
    match Leaf.kind leaf with Kind.Error -> "error" | Requirement -> "witness"
  in
  A.case
    ~lhs:(named_pattern ~loc (Leaf.identity leaf) name)
    ~guard:None
    ~rhs:(callback ~loc:(ghost loc) ~claimed name)

let structural_case ~loc ~claimed leaf atom =
  let name =
    match Leaf.kind leaf with Kind.Error -> "error" | Requirement -> "witness"
  in
  A.case
    ~lhs:(structural_pattern ~loc atom name)
    ~guard:None
    ~rhs:(callback ~loc:(ghost loc) ~claimed name)

let find_catalogue catalogues identity =
  List.filter
    (fun catalogue ->
      Identity.equal identity (Hamlet_subtractor_catalogue.identity catalogue))
    catalogues

let catalogue_for_leaf catalogues leaf =
  match Leaf.materialization leaf with
  | Leaf.Error_cases { catalogue; union; field } -> (
      match find_catalogue catalogues catalogue with
      | [] -> Error (Hamlet_subtractor_generator.Missing_catalogue catalogue)
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
      | _ -> Error (Hamlet_subtractor_generator.Conflicting_catalogue catalogue)
      )
  | _ -> Error (Hamlet_subtractor_generator.Invalid_materialization leaf)

let same_identity_set left right =
  let normalize = List.sort_uniq Identity.compare in
  let left = normalize left and right = normalize right in
  List.length left = List.length right
  && List.for_all2 Identity.equal left right

let input_case_leaves input catalogue =
  Proof.leaves input
  |> List.filter (fun leaf ->
      match Leaf.materialization leaf with
      | Leaf.Error_cases { catalogue = identity; union; _ } ->
          Identity.equal identity
            (Hamlet_subtractor_catalogue.identity catalogue)
          && Identity.equal union (Hamlet_subtractor_catalogue.union catalogue)
      | _ -> false)

let is_full_partition input catalogue =
  let input = input_case_leaves input catalogue in
  let input_identities = List.map Leaf.identity input in
  let catalogue_identities =
    Hamlet_subtractor_catalogue.fields catalogue
    |> List.map (fun (field : Hamlet_subtractor_catalogue.field) -> field.leaf)
  in
  same_identity_set input_identities catalogue_identities

let full_case_catalogues ~catalogues input =
  let candidates =
    Proof.leaves input
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
            let duplicate =
              List.exists
                (fun current ->
                  Identity.equal
                    (Hamlet_subtractor_catalogue.identity current)
                    (Hamlet_subtractor_catalogue.identity catalogue))
                accumulated
            in
            if duplicate || not (is_full_partition input catalogue) then
              loop accumulated rest
            else loop (catalogue :: accumulated) rest)
  in
  loop [] candidates

let cases_function ~loc catalogue name =
  A.pexp_ident ~loc
    {
      txt =
        Longident.Ldot
          (module_lid (Hamlet_subtractor_catalogue.identity catalogue), name);
      loc;
    }

let input_leaf input identity =
  Proof.leaves input
  |> List.find_opt (fun leaf -> Identity.equal identity (Leaf.identity leaf))

let catalogue_record ~loc ~input ~claimed catalogue =
  let fields =
    Hamlet_subtractor_catalogue.fields catalogue
    |> List.map (fun (field : Hamlet_subtractor_catalogue.field) ->
        let leaf =
          match input_leaf input field.leaf with
          | Some leaf -> leaf
          | None -> assert false
        in
        let name = "error" in
        let body = callback ~loc ~claimed:(is_claimed claimed leaf) name in
        let function_ =
          A.pexp_fun ~loc Nolabel None
            (A.ppat_var ~loc { txt = name; loc })
            body
        in
        ( {
            txt =
              Longident.Ldot
                ( module_lid (Hamlet_subtractor_catalogue.identity catalogue),
                  field.name );
            loc;
          },
          function_ ))
  in
  A.pexp_record ~loc fields None

let catalogue_case ~loc ~input ~claimed catalogue =
  let nested_loc = ghost loc in
  let union = Hamlet_subtractor_catalogue.union catalogue in
  let lhs = named_pattern ~loc union "error" in
  let rhs =
    A.pexp_apply ~loc:nested_loc
      (cases_function ~loc:nested_loc catalogue "dispatch")
      [
        (Nolabel, catalogue_record ~loc:nested_loc ~input ~claimed catalogue);
        (Nolabel, A.evar ~loc:nested_loc "error");
      ]
  in
  A.case ~lhs ~guard:None ~rhs

let invariant_case ~loc =
  let loc = ghost loc in
  A.case ~lhs:(A.ppat_any ~loc) ~guard:None
    ~rhs:(A.pexp_assert ~loc (A.ebool ~loc false))

let leaf_case ~loc ~claimed leaf =
  match Leaf.materialization leaf with
  | Leaf.Direct | Leaf.Requirement_tag | Leaf.Error_cases _ ->
      Ok (direct_case ~loc ~claimed leaf)
  | Leaf.Structural_variant -> (
      match Leaf.members leaf with
      | [ atom ] -> Ok (structural_case ~loc ~claimed leaf atom)
      | _ -> Error (Hamlet_subtractor_generator.Invalid_materialization leaf))
  | Leaf.Unavailable _ ->
      Error (Hamlet_subtractor_generator.Invalid_materialization leaf)

let dispatch_cases ~loc ~catalogues ~input ~claimed =
  match full_case_catalogues ~catalogues input with
  | Error _ as error -> error
  | Ok full_catalogues ->
      let catalogue_cases =
        List.map (catalogue_case ~loc ~input ~claimed) full_catalogues
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
      let rec generate accumulated = function
        | [] -> Ok (List.rev accumulated)
        | leaf :: rest -> (
            match leaf_case ~loc ~claimed:(is_claimed claimed leaf) leaf with
            | Error _ as error -> error
            | Ok case -> generate (case :: accumulated) rest)
      in
      let leaves =
        Proof.leaves input
        |> List.filter (fun leaf -> not (belongs_to_full_catalogue leaf))
      in
      Result.map
        (fun direct -> catalogue_cases @ direct @ [ invariant_case ~loc ])
        (generate [] leaves)

let slot ~loc ~catalogues ~input ~claimed =
  match dispatch_cases ~loc ~catalogues ~input ~claimed with
  | Error _ as error -> error
  | Ok cases ->
      let value = "_hamlet_subtractor_value" in
      let body =
        let expression = A.pexp_match ~loc (A.evar ~loc value) cases in
        { expression with pexp_attributes = [ warning_attribute ~loc "-11" ] }
        |> A.pexp_fun ~loc (Labelled "forward") None
             (A.ppat_var ~loc { txt = "forward"; loc })
        |> A.pexp_fun ~loc (Labelled "handled") None
             (A.ppat_var ~loc { txt = "handled"; loc })
        |> A.pexp_fun ~loc Nolabel None (A.ppat_var ~loc { txt = value; loc })
      in
      Ok
        (A.pexp_record ~loc
           [
             ( {
                 txt =
                   Longident.Ldot
                     ( Longident.Ldot
                         (Longident.Lident "Hamlet_subtractor", "Evidence"),
                       "dispatch" );
                 loc;
               },
               body );
           ]
           None)

let bundle ~loc = function [ slot ] -> slot | slots -> A.pexp_tuple ~loc slots
