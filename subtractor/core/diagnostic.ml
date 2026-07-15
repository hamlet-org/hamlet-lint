type payload_shape =
  | Function
  | Object
  | Unresolved_variable
  | Open_variant
  | Package
  | Unsupported_structural_type

type code =
  | Open_row
  | Abstract_alias of Identity.t option
  | Unresolved_row
  | Polymorphic_parameter
  | Opaque_origin
  | Higher_order_flow
  | Invalid_owner
  | Invalid_error_catalogue of string
  | Unsupported_pattern
  | Unsupported_handler_rhs
  | Ambiguous_handler
  | Recursive_dependency of Marker.id list
  | Unsupported_payload of {
      declaration : Identity.t option;
      shape : payload_shape;
    }
  | Leaf_outside_universe of Identity.t
  | Atoms_outside_universe of Atom.t list
  | Partially_handled_group of { leaf : Leaf.t; matched : Atom.t list }
  | Unmaterializable_leaf of Leaf.t
  | Grouped_requirement of Identity.t
  | Duplicate_unguarded_arm of Identity.t
  | Conflicting_recovery_leaf of Identity.t
  | Wrong_channel of { expected : Kind.t; actual : Kind.t }

type t = { marker : Marker.t; code : code }

let normalize_code = function
  | Recursive_dependency markers ->
      Recursive_dependency (List.sort_uniq Marker.compare_id markers)
  | Atoms_outside_universe atoms ->
      Atoms_outside_universe (List.sort_uniq Atom.compare atoms)
  | Partially_handled_group { leaf; matched } ->
      Partially_handled_group
        { leaf; matched = List.sort_uniq Atom.compare matched }
  | code -> code

let make ~marker ~code = { marker; code = normalize_code code }
let marker t = t.marker
let code t = t.code
let fallback t = Kind.explicit_fallback (Marker.kind t.marker)

let identity_name identity = Identity.to_string identity

let channel_name marker =
  match Marker.kind marker with
  | Kind.Error -> "error"
  | Kind.Requirement -> "requirement"

let payload_shape_name = function
  | Function -> "function"
  | Object -> "object"
  | Unresolved_variable -> "unresolved variable"
  | Open_variant -> "open variant"
  | Package -> "first-class module"
  | Unsupported_structural_type -> "unsupported structural type"

let unavailable_reason (reason : Leaf.unmaterializable_reason) =
  match reason with
  | Leaf.Abstract_declaration -> "its declaration is abstract"
  | Leaf.Hidden_alias -> "its alias is hidden"
  | Leaf.Missing_cases_catalogue -> "its error cases catalogue is unavailable"
  | Leaf.No_named_pattern -> "it has no materializable named pattern"
  | Leaf.Grouped_requirement -> "it groups multiple requirement tags"

let message t =
  let fallback = fallback t in
  match t.code with
  | Open_row ->
      Printf.sprintf
        "automatic propagation requires a finite closed row; add [%s]" fallback
  | Abstract_alias None ->
      Printf.sprintf
        "automatic propagation cannot inspect an abstract or hidden %s row \
         alias; add [%s]"
        (channel_name t.marker) fallback
  | Abstract_alias (Some identity) ->
      Printf.sprintf
        "automatic propagation cannot inspect abstract or hidden %s row alias \
         %s; add [%s]"
        (channel_name t.marker) (identity_name identity) fallback
  | Unresolved_row ->
      Printf.sprintf
        "automatic propagation cannot resolve the row variables at this site; \
         add [%s]"
        fallback
  | Polymorphic_parameter ->
      Printf.sprintf
        "automatic propagation cannot close a row rooted in a function \
         parameter; add [%s]"
        fallback
  | Opaque_origin ->
      Printf.sprintf
        "automatic propagation cannot prove the upstream effect origin; add \
         [%s]"
        fallback
  | Higher_order_flow ->
      Printf.sprintf
        "automatic propagation cannot trace this higher-order effect flow; add \
         [%s]"
        fallback
  | Invalid_owner ->
      Printf.sprintf
        "automatic propagation owner is not the canonical \
         Hamlet.Combinators.catch or Hamlet.Combinators.provide; add [%s]"
        fallback
  | Invalid_error_catalogue reason ->
      Printf.sprintf
        "automatic propagation rejected the Errors.Cases catalogue (%s); \
         rebuild the declaring service or add [%s]"
        reason fallback
  | Unsupported_pattern ->
      Printf.sprintf
        "automatic propagation does not support this preceding pattern; add \
         [%s]"
        fallback
  | Unsupported_handler_rhs ->
      Printf.sprintf
        "automatic requirement arms must discharge with Tag.give or forward \
         with Hamlet.Dispatch.need; add [%s]"
        fallback
  | Ambiguous_handler ->
      Printf.sprintf
        "automatic propagation cannot associate this reused handler with one \
         owner; add [%s]"
        fallback
  | Recursive_dependency _ ->
      Printf.sprintf
        "automatic propagation found a recursive marker dependency; make one \
         boundary explicit with [%s]"
        fallback
  | Unsupported_payload { declaration; shape } ->
      let owner =
        match declaration with
        | None -> "a row member"
        | Some identity -> identity_name identity
      in
      Printf.sprintf
        "automatic propagation cannot normalize the %s payload of %s; add [%s]"
        (payload_shape_name shape) owner fallback
  | Leaf_outside_universe identity ->
      Printf.sprintf
        "preceding arm %s is outside the proven %s universe; add [%s]"
        (identity_name identity) (channel_name t.marker) fallback
  | Atoms_outside_universe atoms ->
      Printf.sprintf
        "preceding arm atoms [%s] are outside the proven %s universe; add [%s]"
        (atoms |> List.map Atom.to_string |> String.concat "; ")
        (channel_name t.marker) fallback
  | Partially_handled_group { leaf; matched } ->
      Printf.sprintf
        "preceding arms cover only [%s] from grouped leaf %s; match the \
         complete leaf or add [%s]"
        (matched |> List.map Atom.to_string |> String.concat "; ")
        (leaf |> Leaf.identity |> identity_name)
        fallback
  | Unmaterializable_leaf leaf ->
      let reason =
        match Leaf.materialization leaf with
        | Unavailable reason -> unavailable_reason reason
        | _ -> "it has no supported forwarding form"
      in
      Printf.sprintf "residual leaf %s cannot be generated because %s; add [%s]"
        (leaf |> Leaf.identity |> identity_name)
        reason fallback
  | Grouped_requirement identity ->
      Printf.sprintf
        "requirement leaf %s:\n\
         groups multiple requirement tags and has no single discharge meaning; \
         add [%s]"
        (identity_name identity) fallback
  | Duplicate_unguarded_arm identity ->
      Printf.sprintf
        "more than one unguarded arm covers %s; use one complete arm or add \
         [%s]"
        (identity_name identity) fallback
  | Conflicting_recovery_leaf identity ->
      Printf.sprintf
        "recovery evidence conflicts with certified leaf %s; add [%s]"
        (identity_name identity) fallback
  | Wrong_channel { expected; actual } ->
      Printf.sprintf
        "automatic propagation expected %s evidence but received %s evidence; \
         add [%s]"
        (Kind.to_string expected) (Kind.to_string actual) fallback

let compare = Stdlib.compare
let equal a b = compare a b = 0
