module Core = Hamlet_subtractor_core
module Kind = Core.Kind
module Identity = Core.Identity
module Type_identity = Core.Type_identity
module Atom = Core.Atom
module Leaf = Core.Leaf
module Proof = Core.Proof
module Effect_certificate = Core.Effect_certificate
module Residual = Core.Residual

open Typedtree
open Asttypes

let marker_attribute = "hamlet.subtractor.marker.v1"
let upstream_attribute = "hamlet.subtractor.upstream.v1"
let callee_attribute = "hamlet.subtractor.callee.v1"
let handler_attribute = "hamlet.subtractor.handler.v1"
let owner_attribute = "hamlet.subtractor.owner.v1"
let error_leaf_attribute = "hamlet.subtractor.error_leaf.v1"
let error_union_attribute = "hamlet.subtractor.error_union.v1"
let error_cases_attribute = "hamlet.subtractor.error_cases.v1"
let service_tag_attribute = "hamlet.subtractor.service_tag.v1"

type lookup_failure =
  | Missing_probe_node of { marker_id : string; attribute : string }
  | Duplicate_probe_node of { marker_id : string; attribute : string }
  | Invalid_marker_id of string

type refusal_reason =
  | Lookup_failure of lookup_failure
  | Fake_or_aliased_callee
  | Wrong_hamlet_effect_shape
  | Abstract_or_hidden_alias of Identity.t option
  | Open_row
  | Unresolved_row
  | Polymorphic_parameter
  | Unsupported_payload of Core.Diagnostic.payload_shape
  | Invalid_error_catalogue of string
  | Grouped_requirement of Identity.t
  | Unsupported_pattern
  | Unsupported_handler_rhs
  | Higher_order_flow
  | Opaque_origin
  | Residual_refusal of Core.Diagnostic.code
  | Core_validation_failed of string

type refusal = { marker : Core.Marker.t; reason : refusal_reason }

type resolved = {
  marker : Core.Marker.t;
  input : Proof.t;
  certificate : Effect_certificate.t;
  residual : Residual.t;
  arms : Residual.arm list;
  catalogues : Hamlet_subtractor_catalogue.t list;
}

type outcome = Resolved of resolved | Refused of refusal

let refusal_message (refusal : refusal) =
  let fallback = Core.Marker.kind refusal.marker |> Kind.explicit_fallback in
  let explicit message = Printf.sprintf "%s; add [%s]" message fallback in
  match refusal.reason with
  | Lookup_failure (Missing_probe_node { attribute; _ }) ->
      explicit ("automatic propagation probe is missing " ^ attribute)
  | Lookup_failure (Duplicate_probe_node { attribute; _ }) ->
      explicit ("automatic propagation probe duplicated " ^ attribute)
  | Lookup_failure (Invalid_marker_id _) ->
      explicit "automatic propagation received an invalid marker identity"
  | Fake_or_aliased_callee ->
      explicit
        "automatic propagation owner is not Hamlet.Combinators.catch or provide"
  | Wrong_hamlet_effect_shape ->
      explicit "automatic propagation upstream is not a Hamlet effect"
  | Abstract_or_hidden_alias _ ->
      explicit "automatic propagation cannot inspect an abstract or hidden row"
  | Open_row -> explicit "automatic propagation requires a finite closed row"
  | Unresolved_row ->
      explicit "automatic propagation cannot resolve the row at this site"
  | Polymorphic_parameter ->
      explicit
        "automatic propagation cannot close a row rooted in a function \
         parameter"
  | Unsupported_payload _ ->
      explicit "automatic propagation cannot normalize a row payload"
  | Invalid_error_catalogue message ->
      explicit ("automatic propagation rejected Errors.Cases: " ^ message)
  | Grouped_requirement identity ->
      explicit
        (Printf.sprintf
           "automatic propagation cannot discharge grouped requirement %s"
           (Identity.to_string identity))
  | Unsupported_pattern ->
      explicit "automatic propagation does not support this handler pattern"
  | Unsupported_handler_rhs ->
      explicit "automatic requirement arms must use Tag.give or Dispatch.need"
  | Higher_order_flow ->
      explicit
        "automatic propagation cannot trace this higher-order effect flow"
  | Opaque_origin ->
      explicit "automatic propagation depends on an opaque effect computation"
  | Residual_refusal code ->
      Core.Diagnostic.make ~marker:refusal.marker ~code
      |> Core.Diagnostic.message
  | Core_validation_failed message ->
      explicit ("automatic propagation proof validation failed: " ^ message)

exception Refuse of refusal_reason

let refuse reason = raise (Refuse reason)

let string_payload = function
  | Parsetree.PStr
      [
        {
          pstr_desc =
            Pstr_eval
              ( {
                  pexp_desc =
                    Pexp_constant
                      { pconst_desc = Pconst_string (value, _, _); _ };
                  _;
                },
                _ );
          _;
        };
      ] ->
      Some value
  | _ -> None

let attribute_values name attributes =
  List.filter_map
    (fun (attribute : Parsetree.attribute) ->
      if String.equal attribute.attr_name.txt name then
        string_payload attribute.attr_payload
      else None)
    attributes

let has_attribute name attributes =
  List.exists
    (fun (attribute : Parsetree.attribute) ->
      String.equal attribute.attr_name.txt name)
    attributes

let kind_of_id id =
  if String.starts_with ~prefix:"e:" id then Some Kind.Error
  else if String.starts_with ~prefix:"s:" id then Some Kind.Requirement
  else None

let core_marker id kind (loc : Location.t) =
  let marker_id =
    match Core.Marker.id_of_string id with
    | Ok id -> id
    | Error _ -> refuse (Lookup_failure (Invalid_marker_id id))
  in
  let start_column = loc.loc_start.pos_cnum - loc.loc_start.pos_bol in
  let end_column = loc.loc_end.pos_cnum - loc.loc_end.pos_bol in
  let span =
    Core.Source_span.make ~file:loc.loc_start.pos_fname
      ~start_offset:loc.loc_start.pos_cnum ~end_offset:loc.loc_end.pos_cnum
      ~start_line:loc.loc_start.pos_lnum ~start_column
      ~end_line:loc.loc_end.pos_lnum ~end_column
    |> function
    | Ok span -> span
    | Error _ -> refuse (Core_validation_failed "invalid marker location")
  in
  Core.Marker.make ~id:marker_id ~kind ~span

let uid_compilation_unit (uid : Shape.Uid.t) =
  match uid with
  | Compilation_unit name
  | Item { comp_unit = name; _ }
  | Local_opaque_item { comp_unit = name; _ } ->
      Some name
  | Internal | Predef _ -> None

let current_unit_name () =
  try Some (Env.get_current_unit_name ()) with _ -> None

let split_path path =
  match Path.flatten path with
  | `Contains_apply -> None
  | `Ok (root, suffix) -> Some (Ident.name root, suffix)

let declaration_digest ~context_digest uid =
  match uid_compilation_unit uid with
  | Some unit_name
    when Option.equal String.equal (current_unit_name ()) (Some unit_name) ->
      context_digest
  | Some unit_name -> (
      try Env.crc_of_unit unit_name |> Digest.BLAKE128.to_hex
      with _ -> "uid:" ^ unit_name)
  | None -> context_digest

let identity_of_path ?(allow_current_unit = false) ~context_digest ~uid path =
  let root, suffix =
    match split_path path with
    | Some path -> path
    | None -> refuse (Core_validation_failed "applicative declaration path")
  in
  let segments = root :: suffix in
  let declaration_name, module_path =
    match List.rev segments with
    | [] -> refuse (Core_validation_failed "empty declaration path")
    | declaration_name :: reversed_modules ->
        (declaration_name, List.rev reversed_modules)
  in
  let module_path =
    match module_path with
    | [] when allow_current_unit -> [ "Hamlet_subtractor"; "Current_value" ]
    | [] ->
        refuse
          (Core_validation_failed
             "top-level declarations have no safe materialization path")
    | modules -> modules
  in
  Identity.make ~module_path ~declaration_name
    ~interface_digest:(declaration_digest ~context_digest uid)
  |> function
  | Ok identity -> identity
  | Error _ -> refuse (Core_validation_failed "invalid declaration identity")

let type_identity_of_path ~context_digest env path =
  let path = try Env.normalize_type_path None env path with _ -> path in
  let declaration =
    try Env.find_type path env
    with _ -> refuse (Core_validation_failed "unresolved nominal payload")
  in
  identity_of_path ~context_digest ~uid:declaration.type_uid path

let primitive_of_path env path =
  let primitive_name =
    try
      match (Env.find_type path env).type_uid with
      | Shape.Uid.Predef name -> Some name
      | Compilation_unit _ | Item _ | Local_opaque_item _ | Internal -> None
    with _ -> None
  in
  match primitive_name with
  | Some "unit" -> Some Type_identity.Unit
  | Some "bool" -> Some Type_identity.Bool
  | Some "char" -> Some Type_identity.Char
  | Some "int" -> Some Type_identity.Int
  | Some "int32" -> Some Type_identity.Int32
  | Some "int64" -> Some Type_identity.Int64
  | Some "nativeint" -> Some Type_identity.Nativeint
  | Some "float" -> Some Type_identity.Float
  | Some "string" -> Some Type_identity.String
  | Some "bytes" -> Some Type_identity.Bytes
  | Some _ | None -> None

let rec normalize_payload ~context_digest env type_expression =
  match Types.get_desc type_expression with
  | Tpoly (body, _) -> normalize_payload ~context_digest env body
  | Tconstr (path, arguments, _) -> (
      match primitive_of_path env path with
      | Some primitive -> Type_identity.primitive primitive
      | None ->
          let declaration = type_identity_of_path ~context_digest env path in
          let arguments =
            List.map (normalize_payload ~context_digest env) arguments
          in
          Type_identity.nominal ~declaration ~arguments)
  | Ttuple elements -> (
      if List.exists (fun (label, _) -> Option.is_some label) elements then
        refuse (Unsupported_payload Core.Diagnostic.Unsupported_structural_type);
      let elements =
        List.map
          (fun (_, element) -> normalize_payload ~context_digest env element)
          elements
      in
      Type_identity.tuple elements |> function
      | Ok tuple -> tuple
      | Error _ ->
          refuse
            (Unsupported_payload Core.Diagnostic.Unsupported_structural_type))
  | Tvar _ | Tunivar _ ->
      refuse (Unsupported_payload Core.Diagnostic.Unresolved_variable)
  | Tarrow _ -> refuse (Unsupported_payload Core.Diagnostic.Function)
  | Tobject _ | Tfield _ -> refuse (Unsupported_payload Core.Diagnostic.Object)
  | Tvariant _ -> refuse (Unsupported_payload Core.Diagnostic.Open_variant)
  | Tpackage _ | Tfunctor _ ->
      refuse (Unsupported_payload Core.Diagnostic.Package)
  | Tlink linked | Tsubst (linked, _) ->
      normalize_payload ~context_digest env linked
  | Tnil ->
      refuse (Unsupported_payload Core.Diagnostic.Unsupported_structural_type)

let atom_payload ~context_digest env = function
  | None -> Atom.No_payload
  | Some payload -> Atom.Payload (normalize_payload ~context_digest env payload)

let make_atom ~context_digest ~kind ~declaration env label payload =
  Atom.make ~kind ~declaration ~label
    ~payload:(atom_payload ~context_digest env payload)
  |> function
  | Ok atom -> atom
  | Error _ -> refuse (Core_validation_failed "invalid row member")

type exact_row = { fields : (string * Types.type_expr option) list }

let exact_row env type_expression =
  let rec expand seen type_expression =
    match Types.get_desc type_expression with
    | Tvariant row -> collect seen row [] None
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> expand seen body
    | Tconstr (path, _, _) ->
        if List.exists (Path.same path) seen then refuse Unresolved_row;
        let declaration =
          try Env.find_type path env
          with _ -> refuse (Abstract_or_hidden_alias None)
        in
        if declaration.Types.type_private = Asttypes.Private then
          refuse (Abstract_or_hidden_alias None);
        begin match declaration.type_manifest with
        | None -> refuse (Abstract_or_hidden_alias None)
        | Some manifest -> expand (path :: seen) manifest
        end
    | Tvar _ | Tunivar _ -> refuse Polymorphic_parameter
    | _ -> refuse Unresolved_row
  and collect seen row fields name =
    if not (Types.row_closed row) then refuse Open_row;
    if Option.is_some (Types.row_fixed row) then refuse Unresolved_row;
    let name =
      match (name, Types.row_name row) with
      | None, name -> name
      | name, None -> name
      | Some (left, _), Some (right, _) when Path.same left right -> name
      | Some _, Some _ -> refuse Unresolved_row
    in
    let fields =
      List.fold_left
        (fun fields (label, field) ->
          match Types.row_field_repr field with
          | Rpresent payload -> (label, payload) :: fields
          | Rabsent -> refuse Unresolved_row
          | Reither _ -> refuse Unresolved_row)
        fields (Types.row_fields row)
    in
    let more = Types.row_more row in
    match Types.get_desc more with
    | Tnil -> { fields = List.rev fields }
    | Tvariant more -> collect seen more fields name
    | Tvar _ | Tunivar _ -> refuse Open_row
    | Tconstr _ ->
        let tail = expand seen more in
        { fields = List.rev fields @ tail.fields }
    | Tlink linked | Tsubst (linked, _) -> (
        match Types.get_desc linked with
        | Tvariant more -> collect seen more fields name
        | Tnil -> { fields = List.rev fields }
        | Tconstr _ ->
            let tail = expand seen linked in
            { fields = List.rev fields @ tail.fields }
        | _ -> refuse Unresolved_row)
    | _ -> refuse Unresolved_row
  in
  expand [] type_expression

let expand_exact_row = exact_row

let parent_path = function Path.Pdot (parent, _) -> Some parent | _ -> None

let type_declaration env path =
  try Env.find_type path env with _ -> refuse (Abstract_or_hidden_alias None)

let canonical_type_path env path =
  try Env.normalize_type_path None env path with _ -> path

let identity_of_type_declaration ~context_digest env path =
  let path = canonical_type_path env path in
  let declaration = type_declaration env path in
  (identity_of_path ~context_digest ~uid:declaration.type_uid path, declaration)

let structural_atom_sets_equal left right =
  let normalize atoms = List.sort_uniq Atom.compare_structural atoms in
  let left = normalize left and right = normalize right in
  List.length left = List.length right
  && List.for_all2 Atom.equal_structural left right

let atoms_of_row ~context_digest ~kind ~declaration env row =
  List.map
    (fun (label, payload) ->
      make_atom ~context_digest ~kind ~declaration env label payload)
    row.fields

let error_leaf ~context_digest env ~materialization path =
  let path = canonical_type_path env path in
  let identity, declaration =
    identity_of_type_declaration ~context_digest env path
  in
  if declaration.type_private = Asttypes.Private then
    refuse (Abstract_or_hidden_alias (Some identity));
  if not (has_attribute error_leaf_attribute declaration.type_attributes) then
    refuse
      (Invalid_error_catalogue
         (Printf.sprintf "%s lacks %s" (Path.name path) error_leaf_attribute));
  let manifest =
    match declaration.type_manifest with
    | Some manifest -> manifest
    | None -> refuse (Abstract_or_hidden_alias (Some identity))
  in
  let row = expand_exact_row env manifest in
  let members =
    atoms_of_row ~context_digest ~kind:Kind.Error ~declaration:identity env row
  in
  Leaf.error ~identity ~members ~materialization |> function
  | Ok leaf -> leaf
  | Error _ -> refuse (Core_validation_failed "invalid error leaf")

let arrow_domain type_expression =
  let rec loop type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> loop body
    | Tarrow (_, domain, _, _) -> domain
    | _ ->
        refuse
          (Invalid_error_catalogue
             "Cases field is not a leaf-to-effect callback")
  in
  loop type_expression

let named_type_path type_expression =
  let rec loop type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> loop body
    | Tconstr (path, [], _) -> path
    | _ ->
        refuse
          (Invalid_error_catalogue
             "Cases field domain is not a named zero-argument leaf")
  in
  loop type_expression

let error_catalogue ~context_digest env union_path =
  let union_path = canonical_type_path env union_path in
  let union_identity, union_declaration =
    identity_of_type_declaration ~context_digest env union_path
  in
  if union_declaration.type_private = Asttypes.Private then
    refuse (Abstract_or_hidden_alias (Some union_identity));
  if not (has_attribute error_union_attribute union_declaration.type_attributes)
  then
    refuse
      (Invalid_error_catalogue
         (Printf.sprintf "%s is not a generated error union"
            (Path.name union_path)));
  let errors_path =
    match parent_path union_path with
    | Some parent -> parent
    | None ->
        refuse
          (Invalid_error_catalogue
             "generated error union has no enclosing Errors module")
  in
  let cases_path = Path.Pdot (Path.Pdot (errors_path, "Cases"), "t") in
  let catalogue_identity, cases_declaration =
    identity_of_type_declaration ~context_digest env cases_path
  in
  if not (has_attribute error_cases_attribute cases_declaration.type_attributes)
  then
    refuse
      (Invalid_error_catalogue
         (Printf.sprintf "%s lacks %s" (Path.name cases_path)
            error_cases_attribute));
  let labels =
    match cases_declaration.type_kind with
    | Type_record (labels, _) -> labels
    | _ -> refuse (Invalid_error_catalogue "generated Cases.t is not a record")
  in
  let fields_and_leaves =
    List.map
      (fun (label : Types.label_declaration) ->
        let field = Ident.name label.ld_id in
        let leaf_path = label.ld_type |> arrow_domain |> named_type_path in
        let leaf_identity, _ =
          identity_of_type_declaration ~context_digest env leaf_path
        in
        let materialization =
          Leaf.Error_cases
            { catalogue = catalogue_identity; union = union_identity; field }
        in
        let leaf = error_leaf ~context_digest env ~materialization leaf_path in
        if not (Identity.equal leaf_identity (Leaf.identity leaf)) then
          refuse (Invalid_error_catalogue "leaf identity changed during check");
        ( Hamlet_subtractor_catalogue.{ name = field; leaf = leaf_identity },
          leaf ))
      labels
  in
  let fields, leaves = List.split fields_and_leaves in
  let catalogue =
    Hamlet_subtractor_catalogue.create ~identity:catalogue_identity
      ~union:union_identity ~fields
    |> function
    | Ok catalogue -> catalogue
    | Error _ ->
        refuse
          (Invalid_error_catalogue
             "Cases catalogue has duplicate or empty fields")
  in
  let union_manifest =
    match union_declaration.type_manifest with
    | Some manifest -> manifest
    | None -> refuse (Abstract_or_hidden_alias (Some union_identity))
  in
  let union_row = expand_exact_row env union_manifest in
  let union_atoms =
    atoms_of_row ~context_digest ~kind:Kind.Error ~declaration:union_identity
      env union_row
  in
  let leaf_atoms = List.concat_map Leaf.members leaves in
  if not (structural_atom_sets_equal union_atoms leaf_atoms) then
    refuse
      (Invalid_error_catalogue
         "Cases fields are not a complete partition of Errors.error");
  (leaves, catalogue)

let local_error_union
    ~context_digest
    env
    union_path
    (union_declaration : Types.type_declaration) =
  let union_identity =
    identity_of_path ~context_digest ~uid:union_declaration.Types.type_uid
      union_path
  in
  let errors_path =
    match parent_path union_path with
    | Some path -> path
    | None ->
        refuse
          (Invalid_error_catalogue
             "local generated error union has no Errors module")
  in
  let module_declaration =
    try Env.find_module errors_path env
    with _ ->
      refuse (Invalid_error_catalogue "cannot inspect the local Errors module")
  in
  let signature =
    match module_declaration.md_type with
    | Mty_signature signature -> signature
    | Mty_ident _ | Mty_functor _ | Mty_alias _ ->
        refuse
          (Invalid_error_catalogue
             "local Errors module does not expose a concrete signature")
  in
  let leaf_paths =
    List.filter_map
      (function
        | Types.Sig_type (identifier, declaration, _, _)
          when has_attribute error_leaf_attribute declaration.type_attributes ->
            Some (Path.Pdot (errors_path, Ident.name identifier))
        | Types.Sig_value _ | Types.Sig_type _ | Types.Sig_typext _
        | Types.Sig_module _ | Types.Sig_modtype _ | Types.Sig_class _
        | Types.Sig_class_type _ ->
            None)
      signature
  in
  if leaf_paths = [] then
    refuse (Invalid_error_catalogue "local Errors module has no tagged leaves");
  let leaves =
    List.map
      (error_leaf ~context_digest env ~materialization:Leaf.Direct)
      leaf_paths
  in
  let union_manifest =
    match union_declaration.type_manifest with
    | Some manifest -> manifest
    | None -> refuse (Abstract_or_hidden_alias (Some union_identity))
  in
  let union_row = expand_exact_row env union_manifest in
  let union_atoms =
    atoms_of_row ~context_digest ~kind:Kind.Error ~declaration:union_identity
      env union_row
  in
  if
    not
      (structural_atom_sets_equal union_atoms
         (List.concat_map Leaf.members leaves))
  then
    refuse
      (Invalid_error_catalogue
         "local error leaves are not a complete Errors.error partition");
  (leaves, [])

let generated_error_union
    ~context_digest
    env
    path
    (declaration : Types.type_declaration) =
  (match declaration.Types.type_private with
  | Asttypes.Private ->
      let identity =
        identity_of_path ~context_digest ~uid:declaration.type_uid path
      in
      refuse (Abstract_or_hidden_alias (Some identity))
  | Asttypes.Public -> ());
  let errors_path =
    match parent_path path with
    | Some path -> path
    | None ->
        refuse
          (Invalid_error_catalogue
             "generated error union has no enclosing Errors module")
  in
  let cases_path = Path.Pdot (Path.Pdot (errors_path, "Cases"), "t") in
  let has_cases =
    try
      let cases = Env.find_type cases_path env in
      has_attribute error_cases_attribute cases.type_attributes
    with _ -> false
  in
  if has_cases then
    let leaves, catalogue = error_catalogue ~context_digest env path in
    (leaves, [ catalogue ])
  else
    let is_current =
      Option.equal String.equal
        (uid_compilation_unit declaration.Types.type_uid)
        (current_unit_name ())
    in
    if is_current then local_error_union ~context_digest env path declaration
    else
      refuse
        (Invalid_error_catalogue
           "external error union has no generated Errors.Cases")

let error_union_paths env =
  let rec scan_module depth path declaration paths =
    if depth > 8 then paths
    else
      match Mtype.scrape env declaration.Types.md_type with
      | Mty_signature signature ->
          scan_signature (depth + 1) path signature paths
      | Mty_ident _ | Mty_functor _ | Mty_alias _ -> paths
  and scan_signature depth parent signature paths =
    List.fold_left
      (fun paths item ->
        match item with
        | Types.Sig_type (identifier, declaration, _, _)
          when has_attribute error_union_attribute
                 declaration.Types.type_attributes
               && declaration.type_private = Asttypes.Public ->
            Path.Pdot (parent, Ident.name identifier) :: paths
        | Types.Sig_module (identifier, _, declaration, _, _) ->
            scan_module depth
              (Path.Pdot (parent, Ident.name identifier))
              declaration paths
        | Types.Sig_value _ | Types.Sig_type _ | Types.Sig_typext _
        | Types.Sig_modtype _ | Types.Sig_class _ | Types.Sig_class_type _ ->
            paths)
      paths signature
  in
  Env.fold_modules
    (fun _ path declaration paths -> scan_module 0 path declaration paths)
    None env []
  |> List.sort_uniq Path.compare

let atoms_intersect left right =
  List.exists (fun atom -> List.exists (Atom.equal_structural atom) right) left

let catalogue_error_leaves ~context_digest env input_atoms =
  let present atom atoms = List.exists (Atom.equal_structural atom) atoms in
  let candidates =
    error_union_paths env
    |> List.filter_map (fun path ->
        let path = canonical_type_path env path in
        let identity, declaration =
          identity_of_type_declaration ~context_digest env path
        in
        match (declaration.type_private, declaration.type_manifest) with
        | Asttypes.Private, _ -> None
        | Asttypes.Public, None -> None
        | Asttypes.Public, Some manifest ->
            let row = expand_exact_row env manifest in
            let atoms =
              atoms_of_row ~context_digest ~kind:Kind.Error
                ~declaration:identity env row
            in
            if atoms_intersect atoms input_atoms then Some (path, declaration)
            else None)
  in
  let partitions =
    List.map
      (fun (path, declaration) ->
        generated_error_union ~context_digest env path declaration)
      candidates
  in
  let leaves = List.concat_map fst partitions in
  let catalogues = List.concat_map snd partitions in
  let matching_leaves atom =
    List.filter (fun leaf -> present atom (Leaf.members leaf)) leaves
  in
  List.iter
    (fun leaf ->
      let present =
        List.filter (fun atom -> present atom input_atoms) (Leaf.members leaf)
      in
      if present <> [] && List.length present <> List.length (Leaf.members leaf)
      then
        refuse
          (Invalid_error_catalogue
             (Printf.sprintf "input partially contains grouped leaf %s"
                (Identity.to_string (Leaf.identity leaf)))))
    leaves;
  let unknown =
    List.filter (fun atom -> matching_leaves atom = []) input_atoms
  in
  if leaves <> [] && unknown <> [] then
    refuse
      (Invalid_error_catalogue
         "input atoms do not form a complete generated catalogue partition");
  List.iter
    (fun atom ->
      match matching_leaves atom with
      | [] | [ _ ] -> ()
      | _ :: _ :: _ ->
          refuse
            (Invalid_error_catalogue
               "input atoms map to more than one generated catalogue leaf"))
    input_atoms;
  let selected =
    leaves
    |> List.filter (fun leaf ->
        List.for_all
          (fun member -> present member input_atoms)
          (Leaf.members leaf))
  in
  (selected, catalogues)

let structural_error_leaves ~context_digest env row =
  List.map
    (fun (label, payload) ->
      let identity =
        Identity.make
          ~module_path:[ "Hamlet_subtractor"; "Current_row" ]
          ~declaration_name:("error_" ^ label) ~interface_digest:context_digest
        |> function
        | Ok identity -> identity
        | Error _ ->
            refuse (Core_validation_failed "invalid structural error identity")
      in
      let member =
        make_atom ~context_digest ~kind:Kind.Error ~declaration:identity env
          label payload
      in
      Leaf.error ~identity ~members:[ member ]
        ~materialization:Leaf.Structural_variant
      |> function
      | Ok leaf -> leaf
      | Error _ -> refuse (Core_validation_failed "invalid structural leaf"))
    row.fields

let hamlet_owned_uid uid =
  match uid_compilation_unit uid with
  | Some "Hamlet" -> true
  | Some unit_name -> String.starts_with ~prefix:"Hamlet__" unit_name
  | None -> false

let is_hamlet_never env path =
  try
    let declaration = Env.find_type path env in
    String.equal (Path.last path) "never"
    && hamlet_owned_uid declaration.Types.type_uid
  with _ -> false

let rec resolve_error_row ~context_digest env type_expression =
  match Types.get_desc type_expression with
  | Tconstr (path, [], _) when is_hamlet_never env path -> ([], [])
  | Tconstr (path, [], _) ->
      let path = canonical_type_path env path in
      let declaration = type_declaration env path in
      if declaration.type_private = Asttypes.Private then
        let identity =
          identity_of_path ~allow_current_unit:true ~context_digest
            ~uid:declaration.type_uid path
        in
        refuse (Abstract_or_hidden_alias (Some identity))
      else if has_attribute error_union_attribute declaration.type_attributes
      then generated_error_union ~context_digest env path declaration
      else if has_attribute error_leaf_attribute declaration.type_attributes
      then
        ( [ error_leaf ~context_digest env ~materialization:Leaf.Direct path ],
          [] )
      else
        let identity =
          identity_of_path ~allow_current_unit:true ~context_digest
            ~uid:declaration.type_uid path
        in
        let manifest =
          match declaration.type_manifest with
          | Some manifest when declaration.type_private = Asttypes.Public ->
              manifest
          | Some _ | None -> refuse (Abstract_or_hidden_alias (Some identity))
        in
        let row = expand_exact_row env manifest in
        let structural = structural_error_leaves ~context_digest env row in
        let named, catalogues =
          catalogue_error_leaves ~context_digest env
            (List.concat_map Leaf.members structural)
        in
        if named = [] then (structural, []) else (named, catalogues)
  | Tvariant _ ->
      let row = exact_row env type_expression in
      let structural = structural_error_leaves ~context_digest env row in
      let named, catalogues =
        catalogue_error_leaves ~context_digest env
          (List.concat_map Leaf.members structural)
      in
      if named = [] then (structural, []) else (named, catalogues)
  | Tpoly (body, _) | Tlink body | Tsubst (body, _) ->
      resolve_error_row ~context_digest env body
  | Tvar _ | Tunivar _ -> refuse Polymorphic_parameter
  | _ -> refuse Unresolved_row

let tag_path_from_payload env payload =
  let rec unwrap payload =
    match Types.get_desc payload with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap body
    | Tconstr (p_path, [ service_type ], _) -> (
        let p_declaration = type_declaration env p_path in
        if not (hamlet_owned_uid p_declaration.type_uid) then
          refuse Unresolved_row;
        match Types.get_desc service_type with
        | Tconstr (service_path, [], _) -> (
            let service_path = canonical_type_path env service_path in
            match parent_path service_path with
            | Some tag_module when String.equal (Path.last tag_module) "Tag" ->
                Path.Pdot (tag_module, "r")
            | _ -> refuse Unresolved_row)
        | _ -> refuse Unresolved_row)
    | _ -> refuse Unresolved_row
  in
  unwrap payload

let requirement_leaf
    ~context_digest
    env
    ~expected_label
    ~expected_payload
    tag_path =
  let identity, declaration =
    identity_of_type_declaration ~context_digest env tag_path
  in
  if declaration.type_private = Asttypes.Private then
    refuse (Abstract_or_hidden_alias (Some identity));
  if not (has_attribute service_tag_attribute declaration.type_attributes) then
    refuse (Abstract_or_hidden_alias (Some identity));
  let manifest =
    match declaration.type_manifest with
    | Some manifest -> manifest
    | None -> refuse (Abstract_or_hidden_alias (Some identity))
  in
  let row = expand_exact_row env manifest in
  let label, payload =
    match row.fields with
    | [ member ] -> member
    | _ -> refuse (Grouped_requirement identity)
  in
  if not (String.equal label expected_label) then refuse Unresolved_row;
  let declared_payload = atom_payload ~context_digest env payload in
  let observed_payload = atom_payload ~context_digest env expected_payload in
  if Stdlib.compare declared_payload observed_payload <> 0 then
    refuse Unresolved_row;
  let member =
    Atom.requirement ~declaration:identity ~label ~payload:declared_payload
    |> function
    | Ok atom -> atom
    | Error _ -> refuse (Core_validation_failed "invalid requirement member")
  in
  Leaf.requirement ~identity ~member ~materialization:Leaf.Requirement_tag
  |> function
  | Ok leaf -> leaf
  | Error _ -> refuse (Core_validation_failed "invalid requirement leaf")

let requirement_leaves_of_row ~context_digest env row =
  List.map
    (fun (label, payload) ->
      let payload_type =
        match payload with
        | Some payload -> payload
        | None -> refuse Unresolved_row
      in
      let tag_path = tag_path_from_payload env payload_type in
      requirement_leaf ~context_digest env ~expected_label:label
        ~expected_payload:payload tag_path)
    row.fields

let resolve_requirement_row ~context_digest env type_expression =
  let row, grouped_alias =
    match Types.get_desc type_expression with
    | Tconstr (path, [], _) when is_hamlet_never env path ->
        ({ fields = [] }, None)
    | Tconstr (path, [], _) ->
        let identity, declaration =
          identity_of_type_declaration ~context_digest env path
        in
        let manifest =
          match declaration.type_manifest with
          | Some manifest when declaration.type_private = Asttypes.Public ->
              manifest
          | Some _ | None -> refuse (Abstract_or_hidden_alias (Some identity))
        in
        let grouped_alias =
          if has_attribute service_tag_attribute declaration.type_attributes
          then None
          else Some identity
        in
        (expand_exact_row env manifest, grouped_alias)
    | Tvariant _ -> (exact_row env type_expression, None)
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) ->
        (expand_exact_row env body, None)
    | Tvar _ | Tunivar _ -> refuse Polymorphic_parameter
    | _ -> refuse Unresolved_row
  in
  let leaves = requirement_leaves_of_row ~context_digest env row in
  (match (grouped_alias, leaves) with
  | Some identity, _ :: _ :: _ -> refuse (Grouped_requirement identity)
  | None, _ | Some _, [] | Some _, [ _ ] -> ());
  (leaves, [])

let expected_value env ~loc path =
  try Some (Env.lookup_value ~use:false ~loc path env) with _ -> None

let canonical_hamlet_value
    env
    ~loc
    ~module_name
    ~value_name
    path
    (description : Types.value_description) =
  if not (hamlet_owned_uid description.Types.val_uid) then false
  else if not (String.equal (Path.last path) value_name) then false
  else
    let expected_name =
      Longident.unflatten [ "Hamlet"; module_name; value_name ] |> Option.get
    in
    match expected_value env ~loc expected_name with
    | Some (expected_path, expected_description) ->
        Shape.Uid.equal description.val_uid expected_description.val_uid
        && (Path.same path expected_path
           || String.equal (Path.last path) (Path.last expected_path))
    | None -> false

let verify_owner_callee kind expression =
  match expression.exp_desc with
  | Texp_ident (path, _, description) ->
      let valid =
        match kind with
        | Kind.Error ->
            canonical_hamlet_value expression.exp_env ~loc:expression.exp_loc
              ~module_name:"Combinators" ~value_name:"catch" path description
        | Kind.Requirement ->
            canonical_hamlet_value expression.exp_env ~loc:expression.exp_loc
              ~module_name:"Combinators" ~value_name:"provide" path description
      in
      if not valid then refuse Fake_or_aliased_callee
  | _ -> refuse Fake_or_aliased_callee

let hamlet_channels expression =
  let rec unwrap type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap body
    | Tconstr (path, [ success; errors; requirements ], _) ->
        let declaration = type_declaration expression.exp_env path in
        if
          (not (String.equal (Path.last path) "t"))
          || not (hamlet_owned_uid declaration.type_uid)
        then refuse Wrong_hamlet_effect_shape;
        (success, errors, requirements)
    | _ -> refuse Wrong_hamlet_effect_shape
  in
  unwrap expression.exp_type

let hamlet_channels_of_scheme env type_expression =
  let rec unwrap type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap body
    | Tconstr (path, [ success; errors; requirements ], _) ->
        let declaration = type_declaration env path in
        if
          (not (String.equal (Path.last path) "t"))
          || not (hamlet_owned_uid declaration.type_uid)
        then refuse Wrong_hamlet_effect_shape;
        (success, errors, requirements)
    | _ -> refuse Wrong_hamlet_effect_shape
  in
  unwrap type_expression

let value_origin ~context_digest path (description : Types.value_description) =
  let identity =
    identity_of_path ~allow_current_unit:true ~context_digest
      ~uid:description.Types.val_uid path
  in
  match (uid_compilation_unit description.val_uid, current_unit_name ()) with
  | Some owner, Some current when not (String.equal owner current) ->
      Proof.External_value identity
  | _ -> Proof.Generalized_value identity

let scheme_is_independently_generalized env type_expression =
  Ctype.free_variables ~env type_expression
  |> List.for_all (fun variable ->
      Int.equal (Types.get_level variable) Btype.generic_level)

let proof_of_leaves ~kind ~origin leaves =
  Proof.create ~kind ~origin ~leaves |> function
  | Ok proof -> proof
  | Error _ -> refuse (Core_validation_failed "invalid exact proof")

let resolve_channel ~context_digest ~kind ~origin env type_expression =
  let leaves, catalogues =
    match kind with
    | Kind.Error -> resolve_error_row ~context_digest env type_expression
    | Kind.Requirement ->
        resolve_requirement_row ~context_digest env type_expression
  in
  (proof_of_leaves ~kind ~origin leaves, catalogues)

type principal_row = { exact : exact_row; tail : Types.type_expr }

let principal_row ~allow_named ~generic_tail type_expression =
  let rec unwrap type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap body
    | Tvar _
      when (not generic_tail)
           || Int.equal (Types.get_level type_expression) Btype.generic_level ->
        { exact = { fields = [] }; tail = type_expression }
    | Tvar _ | Tunivar _ -> refuse Polymorphic_parameter
    | Tvariant row -> (
        if Types.row_closed row then refuse Unresolved_row;
        if Option.is_some (Types.row_fixed row) then refuse Unresolved_row;
        if (not allow_named) && Option.is_some (Types.row_name row) then
          refuse Unresolved_row;
        let fields =
          List.map
            (fun (label, field) ->
              match Types.row_field_repr field with
              | Rpresent payload -> (label, payload)
              | Rabsent | Reither _ -> refuse Unresolved_row)
            (Types.row_fields row)
        in
        let tail = Types.row_more row in
        match Types.get_desc tail with
        | Tvar _
          when (not generic_tail)
               || Int.equal (Types.get_level tail) Btype.generic_level ->
            { exact = { fields }; tail }
        | Tvar _ | Tunivar _ -> refuse Polymorphic_parameter
        | _ -> refuse Unresolved_row)
    | _ -> refuse Unresolved_row
  in
  unwrap type_expression

let close_fresh_principal ?(allow_named = false) env ~scheme ~kind =
  let _, original_errors, original_requirements =
    hamlet_channels_of_scheme env scheme
  in
  let original_type =
    match kind with
    | Kind.Error -> original_errors
    | Kind.Requirement -> original_requirements
  in
  let original = principal_row ~allow_named ~generic_tail:true original_type in
  let fresh = Ctype.instance scheme in
  let _, fresh_errors, fresh_requirements =
    hamlet_channels_of_scheme env fresh
  in
  let fresh_type =
    match kind with
    | Kind.Error -> fresh_errors
    | Kind.Requirement -> fresh_requirements
  in
  let fresh = principal_row ~allow_named ~generic_tail:false fresh_type in
  Ctype.unify env fresh.tail (Btype.newgenty Tnil);
  (match Types.get_desc fresh.tail with
  | Tnil -> ()
  | _ -> refuse Unresolved_row);
  (match Types.get_desc original.tail with
  | Tvar _ when Int.equal (Types.get_level original.tail) Btype.generic_level ->
      ()
  | _ -> refuse Polymorphic_parameter);
  original.exact

let resolve_principal_channel
    ?(allow_named = false)
    ~context_digest
    ~kind
    ~origin
    env
    ~scheme =
  let row = close_fresh_principal ~allow_named env ~scheme ~kind in
  let leaves, catalogues =
    match kind with
    | Kind.Error ->
        let structural = structural_error_leaves ~context_digest env row in
        let input_atoms = List.concat_map Leaf.members structural in
        let named, catalogues =
          catalogue_error_leaves ~context_digest env input_atoms
        in
        if named = [] then (structural, []) else (named, catalogues)
    | Kind.Requirement -> (requirement_leaves_of_row ~context_digest env row, [])
  in
  (proof_of_leaves ~kind ~origin leaves, catalogues)

let row_evidence_failure = function
  | Open_row | Unresolved_row | Polymorphic_parameter -> true
  | Abstract_or_hidden_alias _ -> false
  | _ -> false

type value_binding_origin = {
  identifier : Ident.t;
  uid : Shape.Uid.t;
  rhs : expression;
}

let find_value_binding bindings path uid =
  List.find_map
    (fun (binding : value_binding_origin) ->
      let same_identifier =
        match path with
        | Path.Pident identifier -> Ident.same identifier binding.identifier
        | Path.Pdot _ | Path.Papply _ | Path.Pextra_ty _ -> false
      in
      if Shape.Uid.equal uid binding.uid || same_identifier then
        Some binding.rhs
      else None)
    bindings

let canonical_simple_producer expression =
  match expression.exp_desc with
  | Texp_apply
      (({ exp_desc = Texp_ident (path, _, description); _ } as callee), _) ->
      List.exists
        (fun value_name ->
          canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
            ~module_name:"Combinators" ~value_name path description)
        [ "success"; "return"; "fail"; "summon" ]
  | _ -> false

let canonical_combinator_name expression =
  match expression.exp_desc with
  | Texp_ident (path, _, description) ->
      [
        "chain";
        "both";
        "map";
        "catch";
        "catch_defect";
        "map_fail";
        "or_die";
        "thaw";
        "tap";
        "tap_fail";
        "tap_defect";
        "tap_cause";
      ]
      |> List.find_opt (fun value_name ->
          canonical_hamlet_value expression.exp_env ~loc:expression.exp_loc
            ~module_name:"Combinators" ~value_name path description)
  | _ -> None

let positional_arguments arguments =
  arguments
  |> List.filter_map (function
    | Nolabel, Arg expression -> Some expression
    | Nolabel, Omitted () | (Optional _ | Labelled _), _ -> None)

let labelled_argument label arguments =
  arguments
  |> List.find_map (function
    | Labelled actual, Arg expression when String.equal actual label ->
        Some expression
    | Nolabel, _ | Optional _, _ | Labelled _, _ -> None)

let generated_tag_summon expression =
  match expression.exp_desc with
  | Texp_ident (path, _, _) -> (
      match parent_path path with
      | Some tag_module when String.equal (Path.last tag_module) "Tag" ->
          let tag_path = Path.Pdot (tag_module, "r") in
          begin match
            try Some (Env.find_type tag_path expression.exp_env)
            with _ -> None
          with
          | Some declaration ->
              String.equal (Path.last path) "summon"
              && has_attribute service_tag_attribute declaration.type_attributes
          | None -> false
          end
      | Some _ | None -> false)
  | _ -> false

let canonical_binding_operator expression operator expected_name =
  canonical_hamlet_value expression.exp_env ~loc:operator.bop_loc
    ~module_name:"Combinators" ~value_name:expected_name operator.bop_op_path
    operator.bop_op_val

let rec expression_has_independent_origin bindings seen expression =
  if attribute_values owner_attribute expression.exp_attributes <> [] then true
  else if canonical_simple_producer expression then true
  else if generated_tag_summon expression then true
  else
    match expression.exp_desc with
    | Texp_ident (path, _, description) -> (
        let uid = description.Types.val_uid in
        if List.exists (Shape.Uid.equal uid) seen then false
        else
          match (uid_compilation_unit uid, current_unit_name ()) with
          | Some owner, Some current when not (String.equal owner current) ->
              true
          | _ -> (
              match find_value_binding bindings path uid with
              | Some rhs ->
                  expression_has_independent_origin bindings (uid :: seen) rhs
              | None -> false))
    | Texp_apply (callee, arguments) -> (
        if
          local_function_application_has_independent_origin bindings seen callee
        then true
        else
          match canonical_combinator_name callee with
          | Some
              ( "chain" | "catch" | "catch_defect" | "tap" | "tap_fail"
              | "tap_defect" | "tap_cause" ) ->
              begin match
                ( positional_arguments arguments,
                  labelled_argument "handler" arguments,
                  labelled_argument "f" arguments )
              with
              | source :: _, Some handler, _ | source :: _, None, Some handler
                ->
                  expression_has_independent_origin bindings seen source
                  && function_result_has_independent_origin bindings seen
                       handler
              | _ -> false
              end
          | Some "both" -> (
              match positional_arguments arguments with
              | [ left; right ] ->
                  expression_has_independent_origin bindings seen left
                  && expression_has_independent_origin bindings seen right
              | _ -> false)
          | Some ("map" | "map_fail" | "or_die" | "thaw") -> (
              match positional_arguments arguments with
              | source :: _ ->
                  expression_has_independent_origin bindings seen source
              | [] -> false)
          | Some _ -> false
          | None -> false)
    | Texp_let (_, _, body) ->
        expression_has_independent_origin bindings seen body
    | Texp_struct_item (_, body) ->
        expression_has_independent_origin bindings seen body
    | Texp_match (_, cases, _, _) ->
        List.for_all
          (fun (case : computation case) ->
            expression_has_independent_origin bindings seen case.c_rhs)
          cases
    | Texp_ifthenelse (_, if_true, Some if_false) ->
        expression_has_independent_origin bindings seen if_true
        && expression_has_independent_origin bindings seen if_false
    | Texp_sequence (_, last) ->
        expression_has_independent_origin bindings seen last
    | Texp_letop { let_; ands; body; _ }
      when canonical_binding_operator expression let_ "let*"
           && List.for_all
                (fun operator ->
                  canonical_binding_operator expression operator "and*")
                ands ->
        expression_has_independent_origin bindings seen let_.bop_exp
        && List.for_all
             (fun operator ->
               expression_has_independent_origin bindings seen operator.bop_exp)
             ands
        && expression_has_independent_origin bindings seen body.c_rhs
    | Texp_letop { let_; ands; _ }
      when canonical_binding_operator expression let_ "let+"
           && List.for_all
                (fun operator ->
                  canonical_binding_operator expression operator "and*")
                ands ->
        expression_has_independent_origin bindings seen let_.bop_exp
        && List.for_all
             (fun operator ->
               expression_has_independent_origin bindings seen operator.bop_exp)
             ands
    | _ -> false

and function_result_has_independent_origin bindings seen expression =
  match expression.exp_desc with
  | Texp_function (_, Tfunction_body body) ->
      expression_has_independent_origin bindings seen body
  | Texp_function (_, Tfunction_cases { cases; _ }) ->
      List.for_all
        (fun (case : value case) ->
          expression_has_independent_origin bindings seen case.c_rhs)
        cases
  | _ -> false

and local_function_application_has_independent_origin bindings seen callee =
  match callee.exp_desc with
  | Texp_ident (path, _, description) ->
      let uid = description.Types.val_uid in
      if List.exists (Shape.Uid.equal uid) seen then false
      else
        Option.value
          (find_value_binding bindings path uid
          |> Option.map
               (function_result_has_independent_origin bindings (uid :: seen)))
          ~default:false
  | _ -> false

let value_is_independent bindings path description =
  let uid = description.Types.val_uid in
  match (uid_compilation_unit uid, current_unit_name ()) with
  | Some owner, Some current when not (String.equal owner current) -> true
  | _ -> (
      match find_value_binding bindings path uid with
      | Some rhs -> expression_has_independent_origin bindings [ uid ] rhs
      | None -> false)

let has_explicit_type_boundary expression =
  List.exists
    (function
      | Texp_constraint _, _, _ | Texp_coerce _, _, _ -> true
      | Texp_poly _, _, _ | Texp_newtype _, _, _ -> false)
    expression.exp_extra

let direct_application_has_stable_scheme expression =
  match expression.exp_desc with
  | Texp_apply (({ exp_desc = Texp_ident (_, _, description); _ } as callee), _)
    ->
      scheme_is_independently_generalized callee.exp_env
        description.Types.val_type
  | _ -> false

let rec unwrap_scheme type_expression =
  match Types.get_desc type_expression with
  | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap_scheme body
  | _ -> type_expression

let applied_argument_schemes type_expression arguments =
  let rec loop parameters type_expression = function
    | [] -> (type_expression, List.rev parameters)
    | (Nolabel, Arg _) :: rest -> (
        match Types.get_desc (unwrap_scheme type_expression) with
        | Tarrow (Nolabel, parameter, result, _) ->
            loop (parameter :: parameters) result rest
        | Tarrow _ | _ -> refuse Higher_order_flow)
    | _ -> refuse Higher_order_flow
  in
  loop [] type_expression arguments

let type_variables type_expression =
  let variables = ref [] in
  let collect type_expression =
    let type_expression = Types.Transient_expr.repr type_expression in
    match type_expression.desc with
    | Tvar _ | Tunivar _ ->
        if not (List.exists (Int.equal type_expression.id) !variables) then
          variables := type_expression.id :: !variables
    | _ -> ()
  in
  collect type_expression;
  Btype.iter_type_expr collect type_expression;
  !variables

let shares_type_variable left right =
  List.exists
    (fun left_variable ->
      List.exists (Int.equal left_variable) (type_variables right))
    (type_variables left)

let application_result_is_independent ~kind env ~scheme ~arguments =
  let effect_scheme, parameter_schemes =
    applied_argument_schemes scheme arguments
  in
  let _, errors, requirements = hamlet_channels_of_scheme env effect_scheme in
  let target =
    match kind with Kind.Error -> errors | Kind.Requirement -> requirements
  in
  not (List.exists (shares_type_variable target) parameter_schemes)

let local_application_has_parameter_dependent_channel ~bindings ~kind expression
    =
  match expression.exp_desc with
  | Texp_apply
      ( ({ exp_desc = Texp_ident (path, _, description); _ } as callee),
        arguments )
    when Option.is_some
           (find_value_binding bindings path description.Types.val_uid)
         && scheme_is_independently_generalized callee.exp_env
              description.Types.val_type ->
      application_result_is_independent ~kind callee.exp_env
        ~scheme:description.Types.val_type ~arguments
      |> not
  | _ -> false

let resolve_local_application_channel ~context_digest ~bindings ~kind upstream =
  match upstream.exp_desc with
  | Texp_apply
      ( ({ exp_desc = Texp_ident (path, _, description); _ } as callee),
        arguments )
    when local_function_application_has_independent_origin bindings [] callee
         && scheme_is_independently_generalized callee.exp_env
              description.Types.val_type
         && application_result_is_independent ~kind callee.exp_env
              ~scheme:description.Types.val_type ~arguments ->
      let origin = value_origin ~context_digest path description in
      let scheme, _ =
        applied_argument_schemes description.Types.val_type arguments
      in
      resolve_principal_channel ~context_digest ~kind ~origin callee.exp_env
        ~scheme
  | _ -> refuse Higher_order_flow

let resolve_target_channel
    ~context_digest
    ~bindings
    ~kind
    upstream
    occurrence_type =
  match upstream.exp_desc with
  | Texp_ident (path, _, description) ->
      let _, scheme_errors, scheme_requirements =
        hamlet_channels_of_scheme upstream.exp_env description.val_type
      in
      let scheme_type =
        match kind with
        | Kind.Error -> scheme_errors
        | Kind.Requirement -> scheme_requirements
      in
      let origin = value_origin ~context_digest path description in
      begin try
        resolve_channel ~context_digest ~kind ~origin upstream.exp_env
          scheme_type
      with Refuse reason when row_evidence_failure reason ->
        if not (value_is_independent bindings path description) then
          begin match
            find_value_binding bindings path description.Types.val_uid
          with
          | None -> refuse Polymorphic_parameter
          | Some _ -> refuse Higher_order_flow
          end
        else if
          scheme_is_independently_generalized upstream.exp_env
            description.val_type
        then
          resolve_principal_channel ~context_digest ~kind ~origin
            upstream.exp_env ~scheme:description.val_type
        else refuse Polymorphic_parameter
      end
  | _
    when canonical_simple_producer upstream
         || has_explicit_type_boundary upstream ->
      resolve_channel ~context_digest ~kind ~origin:Proof.Closed_row
        upstream.exp_env occurrence_type
  | _
    when local_application_has_parameter_dependent_channel ~bindings ~kind
           upstream ->
      refuse Polymorphic_parameter
  | _ when direct_application_has_stable_scheme upstream ->
      begin try
        resolve_channel ~context_digest ~kind ~origin:Proof.Closed_row
          upstream.exp_env occurrence_type
      with Refuse reason when row_evidence_failure reason ->
        resolve_local_application_channel ~context_digest ~bindings ~kind
          upstream
      end
  | _ -> refuse Higher_order_flow

let try_opposite_channel
    ~context_digest
    ~bindings
    ~kind
    upstream
    type_expression =
  try
    let proof, catalogues =
      resolve_target_channel ~context_digest ~bindings ~kind upstream
        type_expression
    in
    (Effect_certificate.exact proof, catalogues)
  with Refuse _ -> (Effect_certificate.opaque Unproven_origin, [])

let certificate_for_input ~context_digest ~bindings ~kind upstream =
  let _, errors, requirements = hamlet_channels upstream in
  let target_type, opposite_kind, opposite_type =
    match kind with
    | Kind.Error -> (errors, Kind.Requirement, requirements)
    | Kind.Requirement -> (requirements, Kind.Error, errors)
  in
  let input, target_catalogues =
    resolve_target_channel ~context_digest ~bindings ~kind upstream target_type
  in
  let opposite, opposite_catalogues =
    try_opposite_channel ~context_digest ~bindings ~kind:opposite_kind upstream
      opposite_type
  in
  let target = Effect_certificate.exact input in
  let errors, requirements =
    match kind with
    | Kind.Error -> (target, opposite)
    | Kind.Requirement -> (opposite, target)
  in
  let certificate =
    Effect_certificate.create ~errors ~requirements |> function
    | Ok certificate -> certificate
    | Error _ -> refuse (Core_validation_failed "invalid effect certificate")
  in
  (input, certificate, target_catalogues @ opposite_catalogues)

type arm_view =
  | Arm : 'kind general_pattern * expression option * expression -> arm_view

let arms_of_handler handler =
  Hamlet_subtractor_propagate.arms_of_handler handler
  |> Option.map
       (List.map (fun (Hamlet_subtractor_propagate.Arm (pattern, guard, rhs)) ->
            Arm (pattern, guard, rhs)))

let rec type_pattern_paths : type kind. kind general_pattern -> Path.t list =
 fun pattern ->
  let here =
    List.filter_map
      (function Tpat_type (path, _), _, _ -> Some path | _ -> None)
      pattern.pat_extra
  in
  if here <> [] then here
  else
    match pattern.pat_desc with
    | Tpat_value value ->
        type_pattern_paths
          (value : tpat_value_argument :> value general_pattern)
    | Tpat_alias (inner, _, _, _, _) -> type_pattern_paths inner
    | Tpat_any | Tpat_var _ | Tpat_constant _ | Tpat_tuple _ | Tpat_construct _
    | Tpat_variant _ | Tpat_record _ | Tpat_array _ | Tpat_or _ | Tpat_lazy _
    | Tpat_exception _ ->
        []

let alias_variable = Hamlet_subtractor_propagate.alias_var

let is_ident = Hamlet_subtractor_propagate.is_ident_var

let identity_for_pattern ~context_digest ~kind env path =
  let path = canonical_type_path env path in
  let identity, declaration =
    identity_of_type_declaration ~context_digest env path
  in
  let expected_attribute =
    match kind with
    | Kind.Error -> error_leaf_attribute
    | Kind.Requirement -> service_tag_attribute
  in
  let generated =
    has_attribute expected_attribute declaration.type_attributes
  in
  if Kind.equal kind Kind.Requirement && not generated then
    refuse Unsupported_pattern;
  let manifest =
    match declaration.type_manifest with
    | Some manifest -> manifest
    | None -> refuse (Abstract_or_hidden_alias (Some identity))
  in
  let row = expand_exact_row env manifest in
  let members =
    atoms_of_row ~context_digest ~kind ~declaration:identity env row
  in
  if members = [] then refuse Unsupported_pattern;
  (identity, path, members)

let first_positional_argument = Hamlet_subtractor_upstream.extract_upstream

let classify_error_rhs rhs alias =
  match (alias, rhs.exp_desc) with
  | Some identifier, Texp_apply (callee, arguments) -> (
      match (callee.exp_desc, first_positional_argument arguments) with
      | Texp_ident (path, _, description), Some argument
        when canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
               ~module_name:"Combinators" ~value_name:"fail" path description
             && is_ident argument identifier ->
          Residual.Forward
      | _ -> Residual.Handle)
  | _ -> Residual.Handle

let canonical_tag_give env tag_path callee_path description =
  match parent_path tag_path with
  | None -> false
  | Some tag_module -> (
      let expected_path = Path.Pdot (tag_module, "give") in
      let expected =
        try Some (Env.find_value expected_path env) with _ -> None
      in
      String.equal (Path.last callee_path) "give"
      &&
      match expected with
      | Some expected_description ->
          Shape.Uid.equal description.Types.val_uid expected_description.val_uid
      | None -> false)

let classify_requirement_rhs ~tag_path rhs alias =
  match (alias, rhs.exp_desc) with
  | Some identifier, Texp_apply (callee, arguments) -> (
      match (callee.exp_desc, first_positional_argument arguments) with
      | Texp_ident (path, _, description), Some argument
        when is_ident argument identifier ->
          if
            canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
              ~module_name:"Dispatch" ~value_name:"need" path description
          then Residual.Forward
          else if
            canonical_tag_give callee.exp_env tag_path path description
            && List.length arguments >= 2
          then Residual.Handle
          else refuse Unsupported_handler_rhs
      | _ -> refuse Unsupported_handler_rhs)
  | _ -> refuse Unsupported_handler_rhs

let arm_is_marker marker_id (Arm (_, _, rhs)) =
  attribute_values marker_attribute rhs.exp_attributes
  |> List.exists (String.equal marker_id)

type classified_arm = {
  arm : Residual.arm;
  identity : Identity.t;
  members : Atom.t list;
  action : Residual.action;
  rhs : expression;
}

let classify_arms ~context_digest ~kind ~marker_id handler =
  let arms =
    match arms_of_handler handler with
    | Some arms -> arms
    | None -> refuse Unsupported_pattern
  in
  let rec before_marker preceding = function
    | [] -> refuse Unsupported_pattern
    | arm :: rest when arm_is_marker marker_id arm ->
        if rest = [] then List.rev preceding else refuse Unsupported_pattern
    | arm :: rest -> before_marker (arm :: preceding) rest
  in
  before_marker [] arms
  |> List.map (fun (Arm (pattern, guard, rhs)) ->
      let path =
        match type_pattern_paths pattern with
        | [ path ] -> path
        | [] | _ :: _ :: _ -> refuse Unsupported_pattern
      in
      let identity, tag_path, members =
        identity_for_pattern ~context_digest ~kind pattern.pat_env path
      in
      let action =
        match kind with
        | Kind.Error -> classify_error_rhs rhs (alias_variable pattern)
        | Kind.Requirement ->
            classify_requirement_rhs ~tag_path rhs (alias_variable pattern)
      in
      let guard =
        match guard with
        | None -> Residual.Unguarded
        | Some _ -> Residual.Guarded
      in
      {
        arm =
          Residual.arm ~target:(Residual.Complete_leaf identity) ~guard ~action;
        identity;
        members;
        action;
        rhs;
      })

type expression_nodes = {
  upstreams : (string, expression list) Hashtbl.t;
  callees : (string, expression list) Hashtbl.t;
  handlers : (string, expression list) Hashtbl.t;
  markers : (string, expression list) Hashtbl.t;
  mutable bindings : value_binding_origin list;
}

let add_node table id expression =
  let existing = Option.value (Hashtbl.find_opt table id) ~default:[] in
  Hashtbl.replace table id (expression :: existing)

let collect_expression_nodes structure =
  let nodes =
    {
      upstreams = Hashtbl.create 16;
      callees = Hashtbl.create 16;
      handlers = Hashtbl.create 16;
      markers = Hashtbl.create 16;
      bindings = [];
    }
  in
  let iterator =
    let default = Tast_iterator.default_iterator in
    {
      default with
      value_binding =
        (fun self binding ->
          let bound = ref [] in
          let pattern_iterator =
            let pattern_default = Tast_iterator.default_iterator in
            {
              pattern_default with
              pat =
                (fun (type kind) self (pattern : kind general_pattern) ->
                  (match pattern.pat_desc with
                  | Tpat_var (identifier, _, uid)
                  | Tpat_alias (_, identifier, _, uid, _) ->
                      bound := (identifier, uid) :: !bound
                  | _ -> ());
                  pattern_default.pat self pattern);
            }
          in
          pattern_iterator.pat pattern_iterator binding.vb_pat;
          List.iter
            (fun (identifier, uid) ->
              nodes.bindings <-
                { identifier; uid; rhs = binding.vb_expr } :: nodes.bindings)
            !bound;
          default.value_binding self binding);
      expr =
        (fun self expression ->
          let collect name table =
            attribute_values name expression.exp_attributes
            |> List.iter (fun id -> add_node table id expression)
          in
          collect upstream_attribute nodes.upstreams;
          collect callee_attribute nodes.callees;
          collect handler_attribute nodes.handlers;
          collect marker_attribute nodes.markers;
          default.expr self expression);
    }
  in
  iterator.structure iterator structure;
  nodes

let require_node table ~marker_id ~attribute =
  match Hashtbl.find_opt table marker_id with
  | Some [ expression ] -> expression
  | None | Some [] ->
      refuse (Lookup_failure (Missing_probe_node { marker_id; attribute }))
  | Some (_ :: _ :: _) ->
      refuse (Lookup_failure (Duplicate_probe_node { marker_id; attribute }))

let marker_dependencies nodes marker_id upstream =
  let dependencies = ref [] in
  let visited = ref [] in
  let iterator =
    let default = Tast_iterator.default_iterator in
    {
      default with
      expr =
        (fun self expression ->
          attribute_values owner_attribute expression.exp_attributes
          |> List.iter (fun id ->
              if not (String.equal id marker_id) then
                dependencies := id :: !dependencies);
          (match expression.exp_desc with
          | Texp_ident (path, _, description) ->
              let uid = description.Types.val_uid in
              if not (List.exists (Shape.Uid.equal uid) !visited) then (
                visited := uid :: !visited;
                Option.iter (self.expr self)
                  (find_value_binding nodes.bindings path uid))
          | _ -> ());
          default.expr self expression);
    }
  in
  iterator.expr iterator upstream;
  List.sort_uniq String.compare !dependencies

let exact_evidence kind certificate =
  let evidence =
    match kind with
    | Kind.Error -> Effect_certificate.errors certificate
    | Kind.Requirement -> Effect_certificate.requirements certificate
  in
  match Effect_certificate.evidence_view evidence with
  | Exact_proof proof -> proof
  | Opaque_reasons _ -> refuse Opaque_origin

let empty_proof kind operation =
  Proof.create ~kind
    ~origin:(Proof.Composition { operation; inputs = [] })
    ~leaves:[]
  |> function
  | Ok proof -> proof
  | Error _ -> refuse (Core_validation_failed "invalid empty proof")

let exact_certificate ~errors ~requirements =
  Effect_certificate.create
    ~errors:(Effect_certificate.exact errors)
    ~requirements:(Effect_certificate.exact requirements)
  |> function
  | Ok certificate -> certificate
  | Error _ -> refuse (Core_validation_failed "invalid exact certificate")

let structural_variant_leaf ~context_digest env label payload =
  let identity =
    Identity.make
      ~module_path:[ "Hamlet_subtractor"; "Current_expression" ]
      ~declaration_name:("error_" ^ label) ~interface_digest:context_digest
    |> function
    | Ok identity -> identity
    | Error _ -> refuse (Core_validation_failed "invalid expression identity")
  in
  let payload = Option.map (fun payload -> payload.exp_type) payload in
  let member =
    make_atom ~context_digest ~kind:Kind.Error ~declaration:identity env label
      payload
  in
  Leaf.error ~identity ~members:[ member ]
    ~materialization:Leaf.Structural_variant
  |> function
  | Ok leaf -> leaf
  | Error _ -> refuse (Core_validation_failed "invalid expression leaf")

let generated_summon_certificate ~context_digest expression path description =
  match parent_path path with
  | Some tag_module when String.equal (Path.last tag_module) "Tag" ->
      let tag_path = Path.Pdot (tag_module, "r") in
      let tag_identity, tag_declaration =
        identity_of_type_declaration ~context_digest expression.exp_env tag_path
      in
      if
        not
          (String.equal (Path.last path) "summon"
          && has_attribute service_tag_attribute
               tag_declaration.Types.type_attributes)
      then None
      else
        let origin = value_origin ~context_digest path description in
        let requirements, catalogues =
          resolve_principal_channel ~context_digest ~kind:Kind.Requirement
            ~allow_named:true ~origin expression.exp_env
            ~scheme:description.Types.val_type
        in
        begin match Proof.leaves requirements with
        | [ leaf ] when Identity.equal tag_identity (Leaf.identity leaf) ->
            Some
              ( exact_certificate
                  ~errors:(empty_proof Kind.Error Proof.Summon)
                  ~requirements,
                catalogues )
        | _ -> None
        end
  | Some _ | None -> None

let positional_arguments arguments =
  List.filter_map
    (function Asttypes.Nolabel, Arg expression -> Some expression | _ -> None)
    arguments

let canonical_tag_value env tag_module name path description =
  let expected_path = Path.Pdot (tag_module, name) in
  match try Some (Env.find_value expected_path env) with _ -> None with
  | Some expected ->
      String.equal (Path.last path) name
      && Shape.Uid.equal description.Types.val_uid expected.Types.val_uid
  | None -> false

let service_key_matches_tag env tag_module type_expression =
  let rec unwrap type_expression =
    match Types.get_desc type_expression with
    | Tpoly (body, _) | Tlink body | Tsubst (body, _) -> unwrap body
    | Tconstr (path, [ service ], _) ->
        let declaration = type_declaration env path in
        let canonical_service =
          match Types.get_desc service with
          | Tconstr (service_path, [], _) ->
              canonical_type_path env service_path
          | _ -> refuse Unresolved_row
        in
        let expected_service =
          canonical_type_path env (Path.Pdot (tag_module, "t"))
        in
        hamlet_owned_uid declaration.Types.type_uid
        && String.equal (Path.last path) "t"
        && Option.exists
             (fun parent -> String.equal (Path.last parent) "Service_key")
             (parent_path path)
        && Path.same canonical_service expected_service
    | _ -> false
  in
  unwrap type_expression

let generated_summon_call_certificate ~context_digest expression arguments =
  match positional_arguments arguments with
  | [ key; tag ] -> (
      match (key.exp_desc, tag.exp_desc) with
      | ( Texp_ident (key_path, _, key_description),
          Texp_ident (tag_path, _, tag_description) ) -> (
          match parent_path key_path with
          | Some tag_module
            when String.equal (Path.last tag_module) "Tag"
                 && canonical_tag_value key.exp_env tag_module "key" key_path
                      key_description
                 && canonical_tag_value tag.exp_env tag_module "tag" tag_path
                      tag_description
                 && service_key_matches_tag key.exp_env tag_module key.exp_type
            ->
              let tag_type_path = Path.Pdot (tag_module, "r") in
              let tag_identity, tag_declaration =
                identity_of_type_declaration ~context_digest expression.exp_env
                  tag_type_path
              in
              if
                not
                  (has_attribute service_tag_attribute
                     tag_declaration.Types.type_attributes)
              then None
              else
                let manifest =
                  match tag_declaration.type_manifest with
                  | Some manifest -> manifest
                  | None ->
                      refuse (Abstract_or_hidden_alias (Some tag_identity))
                in
                let declared = expand_exact_row expression.exp_env manifest in
                let observed =
                  principal_row ~allow_named:true ~generic_tail:true
                    tag_description.Types.val_type
                in
                (match Types.get_desc observed.tail with
                | Tvar _
                  when Int.equal
                         (Types.get_level observed.tail)
                         Btype.generic_level ->
                    ()
                | _ -> refuse Unresolved_row);
                let declared_atoms =
                  atoms_of_row ~context_digest ~kind:Kind.Requirement
                    ~declaration:tag_identity expression.exp_env declared
                in
                let observed_atoms =
                  atoms_of_row ~context_digest ~kind:Kind.Requirement
                    ~declaration:tag_identity expression.exp_env observed.exact
                in
                if
                  not (structural_atom_sets_equal declared_atoms observed_atoms)
                then refuse Unresolved_row;
                let requirement_leaves, catalogues =
                  resolve_requirement_row ~context_digest expression.exp_env
                    manifest
                in
                let requirements =
                  proof_of_leaves ~kind:Kind.Requirement
                    ~origin:
                      (Proof.Composition
                         { operation = Proof.Summon; inputs = [] })
                    requirement_leaves
                in
                begin match Proof.leaves requirements with
                | [ leaf ] when Identity.equal tag_identity (Leaf.identity leaf)
                  ->
                    Some
                      ( exact_certificate
                          ~errors:(empty_proof Kind.Error Proof.Summon)
                          ~requirements,
                        catalogues )
                | _ -> None
                end
          | Some _ | None -> None)
      | _ -> None)
  | _ -> None

let intrinsic_certificate ~context_digest expression =
  match expression.exp_desc with
  | Texp_ident (path, _, description) ->
      generated_summon_certificate ~context_digest expression path description
  | Texp_apply (callee, arguments) -> (
      match callee.exp_desc with
      | Texp_ident (path, _, description)
        when canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
               ~module_name:"Combinators" ~value_name:"summon" path description
        ->
          generated_summon_call_certificate ~context_digest expression arguments
      | Texp_ident (path, _, description)
        when canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
               ~module_name:"Combinators" ~value_name:"success" path description
             || canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
                  ~module_name:"Combinators" ~value_name:"return" path
                  description ->
          Some
            ( exact_certificate
                ~errors:(empty_proof Kind.Error Proof.Return)
                ~requirements:(empty_proof Kind.Requirement Proof.Return),
              [] )
      | Texp_ident (path, _, description)
        when canonical_hamlet_value callee.exp_env ~loc:callee.exp_loc
               ~module_name:"Combinators" ~value_name:"fail" path description ->
          let argument =
            match first_positional_argument arguments with
            | Some argument -> argument
            | None -> refuse Unresolved_row
          in
          let leaf =
            match argument.exp_desc with
            | Texp_variant (label, payload) ->
                structural_variant_leaf ~context_digest argument.exp_env label
                  payload
            | _ -> refuse Unresolved_row
          in
          let leaves, catalogues =
            let named, catalogues =
              catalogue_error_leaves ~context_digest argument.exp_env
                (Leaf.members leaf)
            in
            if named = [] then ([ leaf ], []) else (named, catalogues)
          in
          let errors =
            proof_of_leaves ~kind:Kind.Error
              ~origin:
                (Proof.Composition { operation = Proof.Fail; inputs = [] })
              leaves
          in
          Some
            ( exact_certificate ~errors
                ~requirements:(empty_proof Kind.Requirement Proof.Fail),
              catalogues )
      | _ -> None)
  | _ -> None

let recovery_certificate
    ~context_digest
    ~bindings:_
    (classified : classified_arm) =
  let opaque () =
    let certificate =
      Effect_certificate.create
        ~errors:(Effect_certificate.opaque Opaque_recovery)
        ~requirements:(Effect_certificate.opaque Opaque_recovery)
      |> function
      | Ok certificate -> certificate
      | Error _ ->
          refuse (Core_validation_failed "invalid opaque recovery certificate")
    in
    (certificate, [])
  in
  try
    match intrinsic_certificate ~context_digest classified.rhs with
    | Some certificate -> certificate
    | None -> opaque ()
  with Refuse _ -> opaque ()

type node = {
  marker : Core.Marker.t;
  dependencies : string list;
  base_certificate : Effect_certificate.t option;
  arms : Residual.arm list;
  arm_members : (Identity.t * Atom.t list) list;
  recoveries : Effect_certificate.t list;
  catalogues : Hamlet_subtractor_catalogue.t list;
}

let extract_node ~context_digest nodes marker_id marker_expression =
  let kind =
    match kind_of_id marker_id with
    | Some kind -> kind
    | None -> refuse (Lookup_failure (Invalid_marker_id marker_id))
  in
  let marker = core_marker marker_id kind marker_expression.exp_loc in
  let upstream =
    require_node nodes.upstreams ~marker_id ~attribute:upstream_attribute
  in
  let callee =
    require_node nodes.callees ~marker_id ~attribute:callee_attribute
  in
  let handler =
    require_node nodes.handlers ~marker_id ~attribute:handler_attribute
  in
  verify_owner_callee kind callee;
  let dependencies = marker_dependencies nodes marker_id upstream in
  let base_certificate, source_catalogues =
    if dependencies = [] then
      let _, certificate, catalogues =
        certificate_for_input ~context_digest ~bindings:nodes.bindings ~kind
          upstream
      in
      (Some certificate, catalogues)
    else (None, [])
  in
  let classified_arms =
    classify_arms ~context_digest ~kind ~marker_id handler
  in
  let recoveries, recovery_catalogues =
    if Kind.equal kind Kind.Error then
      classified_arms
      |> List.filter (fun classified ->
          match classified.action with
          | Residual.Handle -> true
          | Forward -> false)
      |> List.map
           (recovery_certificate ~context_digest ~bindings:nodes.bindings)
      |> List.split
    else ([], [])
  in
  {
    marker;
    dependencies;
    base_certificate;
    arms = List.map (fun classified -> classified.arm) classified_arms;
    arm_members =
      List.map
        (fun classified -> (classified.identity, classified.members))
        classified_arms;
    recoveries;
    catalogues = source_catalogues @ List.concat recovery_catalogues;
  }

let member_present atom members =
  List.exists (Atom.equal_structural atom) members

let normalized_arm_members arm_members =
  List.fold_left
    (fun normalized (identity, members) ->
      match
        List.find_map
          (fun (candidate, existing) ->
            if Identity.equal identity candidate then Some existing else None)
          normalized
      with
      | None -> (identity, members) :: normalized
      | Some existing when structural_atom_sets_equal existing members ->
          normalized
      | Some _ -> refuse Unsupported_pattern)
    [] arm_members

let structural_remainder_leaf marker atom =
  let identity =
    Identity.make
      ~module_path:[ "Hamlet_subtractor"; "Residual" ]
      ~declaration_name:("error_" ^ Atom.label atom)
      ~interface_digest:(marker |> Core.Marker.id |> Core.Marker.id_to_string)
    |> function
    | Ok identity -> identity
    | Error _ -> refuse (Core_validation_failed "invalid residual identity")
  in
  Leaf.error ~identity ~members:[ atom ]
    ~materialization:Leaf.Structural_variant
  |> function
  | Ok leaf -> leaf
  | Error _ -> refuse (Core_validation_failed "invalid residual leaf")

let named_leaf kind identity members =
  match kind with
  | Kind.Error -> (
      Leaf.error ~identity ~members ~materialization:Leaf.Direct |> function
      | Ok leaf -> leaf
      | Error _ -> refuse Unsupported_pattern)
  | Kind.Requirement -> (
      match members with
      | [ member ] -> (
          Leaf.requirement ~identity ~member
            ~materialization:Leaf.Requirement_tag
          |> function
          | Ok leaf -> leaf
          | Error _ -> refuse Unsupported_pattern)
      | _ -> refuse (Grouped_requirement identity))

let align_input_with_arms (node : node) input =
  let kind = Proof.kind input in
  let input_atoms = Proof.atoms input in
  let specs = normalized_arm_members node.arm_members in
  List.iter
    (fun (identity, members) ->
      let missing =
        List.filter (fun atom -> not (member_present atom input_atoms)) members
      in
      match missing with
      | [] -> ()
      | _ when List.length missing = List.length members ->
          refuse
            (Residual_refusal (Core.Diagnostic.Leaf_outside_universe identity))
      | _ ->
          refuse
            (Residual_refusal (Core.Diagnostic.Atoms_outside_universe missing)))
    specs;
  let rec check_disjoint seen = function
    | [] -> ()
    | (_, members) :: rest ->
        if List.exists (fun atom -> member_present atom seen) members then
          refuse Unsupported_pattern;
        check_disjoint (members @ seen) rest
  in
  check_disjoint [] specs;
  let missing =
    List.filter
      (fun (identity, _) -> Option.is_none (Proof.find_leaf input identity))
      specs
  in
  if missing = [] then input
  else
    let consumed = List.concat_map snd missing in
    let retained =
      Proof.leaves input
      |> List.concat_map (fun leaf ->
          let members = Leaf.members leaf in
          let remaining =
            List.filter
              (fun member -> not (member_present member consumed))
              members
          in
          if List.length remaining = List.length members then [ leaf ]
          else if remaining = [] then []
          else
            match (kind, Leaf.materialization leaf) with
            | Kind.Error, Leaf.Error_cases _ ->
                refuse
                  (Invalid_error_catalogue
                     "handler partially intersects a grouped Cases leaf")
            | Kind.Error, _ ->
                List.map (structural_remainder_leaf node.marker) remaining
            | Kind.Requirement, _ -> refuse Unsupported_pattern)
    in
    let named =
      List.map
        (fun (identity, members) -> named_leaf kind identity members)
        missing
    in
    Proof.create ~kind ~origin:(Proof.origin input) ~leaves:(named @ retained)
    |> function
    | Ok proof -> proof
    | Error _ -> refuse Unsupported_pattern

let residual_for_node (node : node) source =
  let kind = Core.Marker.kind node.marker in
  let input = exact_evidence kind source |> align_input_with_arms node in
  let recovery =
    match kind with
    | Kind.Error ->
        node.recoveries
        |> List.concat_map (fun certificate ->
            match
              certificate
              |> Effect_certificate.errors
              |> Effect_certificate.evidence_view
            with
            | Exact_proof proof -> Proof.leaves proof
            | Opaque_reasons _ -> [])
    | Kind.Requirement -> []
  in
  Residual.calculate ~input ~arms:node.arms ~recovery |> function
  | Ok residual -> residual
  | Error code -> refuse (Residual_refusal code)

let output_certificate (node : node) source residual =
  let input_id = Core.Marker.id node.marker in
  let aligned = Effect_certificate.exact (Residual.input residual) in
  let source =
    let errors, requirements =
      match Core.Marker.kind node.marker with
      | Kind.Error -> (aligned, Effect_certificate.requirements source)
      | Kind.Requirement -> (Effect_certificate.errors source, aligned)
    in
    Effect_certificate.create ~errors ~requirements |> function
    | Ok source -> source
    | Error _ ->
        refuse (Core_validation_failed "cannot align source certificate")
  in
  (match Core.Marker.kind node.marker with
    | Kind.Error ->
        Effect_certificate.catch ~inputs:[ input_id ] ~source
          ~error_result:residual ~recoveries:node.recoveries
    | Kind.Requirement ->
        Effect_certificate.provide ~inputs:[ input_id ] ~source
          ~requirement_result:residual ~handlers:[])
  |> function
  | Ok certificate -> certificate
  | Error _ -> refuse (Core_validation_failed "effect composition failed")

let resolve_node_without_dependencies (node : node) =
  if node.dependencies <> [] then refuse Higher_order_flow;
  let source =
    match node.base_certificate with
    | Some source -> source
    | None -> refuse Higher_order_flow
  in
  let residual = residual_for_node node source in
  let certificate = output_certificate node source residual in
  {
    marker = node.marker;
    input = Residual.input residual;
    certificate;
    residual;
    arms = node.arms;
    catalogues = node.catalogues;
  }

let resolve_typedtree ~context_digest structure =
  let nodes = collect_expression_nodes structure in
  let marker_ids =
    Hashtbl.to_seq_keys nodes.markers |> List.of_seq |> List.sort String.compare
  in
  List.map
    (fun marker_id ->
      let marker_expression =
        match Hashtbl.find_opt nodes.markers marker_id with
        | Some (expression :: _) -> expression
        | None | Some [] -> assert false
      in
      let kind = Option.value (kind_of_id marker_id) ~default:Kind.Error in
      let marker =
        try core_marker marker_id kind marker_expression.exp_loc
        with Refuse _ ->
          let fallback_id =
            Core.Marker.id_of_string
              ("invalid:" ^ Digest.to_hex (Digest.string marker_id))
            |> Result.get_ok
          in
          let loc = marker_expression.exp_loc in
          let span =
            Core.Source_span.make ~file:loc.loc_start.pos_fname
              ~start_offset:loc.loc_start.pos_cnum
              ~end_offset:loc.loc_end.pos_cnum
              ~start_line:loc.loc_start.pos_lnum
              ~start_column:(loc.loc_start.pos_cnum - loc.loc_start.pos_bol)
              ~end_line:loc.loc_end.pos_lnum
              ~end_column:(loc.loc_end.pos_cnum - loc.loc_end.pos_bol)
            |> Result.get_ok
          in
          Core.Marker.make ~id:fallback_id ~kind ~span
      in
      try
        extract_node ~context_digest nodes marker_id marker_expression
        |> resolve_node_without_dependencies
        |> fun resolved -> Resolved resolved
      with Refuse reason -> Refused { marker; reason })
    marker_ids

let diagnostic_code = function
  | Lookup_failure _ -> Core.Diagnostic.Higher_order_flow
  | Fake_or_aliased_callee -> Core.Diagnostic.Invalid_owner
  | Wrong_hamlet_effect_shape -> Core.Diagnostic.Opaque_origin
  | Abstract_or_hidden_alias identity -> Core.Diagnostic.Abstract_alias identity
  | Open_row -> Core.Diagnostic.Open_row
  | Unresolved_row -> Core.Diagnostic.Unresolved_row
  | Polymorphic_parameter -> Core.Diagnostic.Polymorphic_parameter
  | Unsupported_payload shape ->
      Core.Diagnostic.Unsupported_payload { declaration = None; shape }
  | Invalid_error_catalogue reason ->
      Core.Diagnostic.Invalid_error_catalogue reason
  | Grouped_requirement identity -> Core.Diagnostic.Grouped_requirement identity
  | Unsupported_pattern -> Core.Diagnostic.Unsupported_pattern
  | Unsupported_handler_rhs -> Core.Diagnostic.Unsupported_handler_rhs
  | Higher_order_flow -> Core.Diagnostic.Higher_order_flow
  | Opaque_origin -> Core.Diagnostic.Opaque_origin
  | Residual_refusal code -> code
  | Core_validation_failed _ -> Core.Diagnostic.Opaque_origin

type engine_context = { nodes : node list; failures : refusal list }

let marker_id_string marker =
  marker |> Core.Marker.id |> Core.Marker.id_to_string

let find_node (context : engine_context) marker =
  let id = Core.Marker.id marker in
  List.find_opt
    (fun (node : node) ->
      Core.Marker.compare_id id (Core.Marker.id node.marker) = 0)
    context.nodes

let find_failure (context : engine_context) marker =
  let id = Core.Marker.id marker in
  List.find_opt
    (fun (refusal : refusal) ->
      Core.Marker.compare_id id (Core.Marker.id refusal.marker) = 0)
    context.failures

let engine_backend =
  let dependencies context marker =
    match find_failure context marker with
    | Some refusal -> Error (diagnostic_code refusal.reason)
    | None -> (
        match find_node context marker with
        | None -> Error Core.Diagnostic.Higher_order_flow
        | Some node ->
            node.dependencies
            |> List.map (fun id ->
                Core.Marker.id_of_string id |> function
                | Ok id -> id
                | Error _ -> refuse Higher_order_flow)
            |> fun dependencies -> Ok dependencies)
  in
  let resolve context ~marker ~dependencies =
    match find_failure context marker with
    | Some refusal -> Error (diagnostic_code refusal.reason)
    | None -> (
        match find_node context marker with
        | None -> Error Core.Diagnostic.Higher_order_flow
        | Some node -> (
            try
              let source =
                match (node.dependencies, dependencies) with
                | [], [] -> (
                    match node.base_certificate with
                    | Some certificate -> certificate
                    | None -> refuse Higher_order_flow)
                | [ _ ], [ (_, (resolved : Hamlet_subtractor_engine.resolved)) ]
                  ->
                    resolved.certificate
                | _ -> refuse Higher_order_flow
              in
              let residual = residual_for_node node source in
              let certificate = output_certificate node source residual in
              Ok Hamlet_subtractor_engine.{ residual; certificate }
            with Refuse reason -> Error (diagnostic_code reason)))
  in
  Hamlet_subtractor_engine.{ dependencies; resolve }

let extract_engine_context ~context_digest structure =
  let expressions = collect_expression_nodes structure in
  let marker_ids =
    Hashtbl.to_seq_keys expressions.markers
    |> List.of_seq
    |> List.sort String.compare
  in
  let nodes, failures, markers =
    List.fold_left
      (fun (nodes, failures, markers) marker_id ->
        match Hashtbl.find_opt expressions.markers marker_id with
        | Some (marker_expression :: _) -> (
            let kind =
              Option.value (kind_of_id marker_id) ~default:Kind.Error
            in
            let marker = core_marker marker_id kind marker_expression.exp_loc in
            try
              let node =
                extract_node ~context_digest expressions marker_id
                  marker_expression
              in
              (node :: nodes, failures, marker :: markers)
            with Refuse reason ->
              (nodes, { marker; reason } :: failures, marker :: markers))
        | None | Some [] -> (nodes, failures, markers))
      ([], [], []) marker_ids
  in
  ({ nodes = List.rev nodes; failures = List.rev failures }, List.rev markers)

let elaborate_typedtree ~context_digest structure =
  let context, markers = extract_engine_context ~context_digest structure in
  let catalogues =
    context.nodes
    |> List.concat_map (fun (node : node) -> node.catalogues)
    |> List.sort_uniq Hamlet_subtractor_catalogue.compare
  in
  match
    Hamlet_subtractor_engine.elaborate ~backend:engine_backend ~context
      ~catalogues ~markers
  with
  | Ok engine -> Ok engine
  | Error (Hamlet_subtractor_engine.Duplicate_marker _) -> (
      match markers with
      | marker :: _ ->
          Error
            {
              marker;
              reason =
                Lookup_failure
                  (Duplicate_probe_node
                     {
                       marker_id = marker_id_string marker;
                       attribute = marker_attribute;
                     });
            }
      | [] -> assert false)
