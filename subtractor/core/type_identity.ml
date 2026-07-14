type primitive =
  | Unit
  | Bool
  | Char
  | Int
  | Int32
  | Int64
  | Nativeint
  | Float
  | String
  | Bytes

type t =
  | Primitive of primitive
  | Tuple of t list
  | Nominal of { declaration : Identity.t; arguments : t list }

type view = t =
  | Primitive of primitive
  | Tuple of t list
  | Nominal of { declaration : Identity.t; arguments : t list }

type validation_error = Tuple_requires_two_elements

let primitive primitive = Primitive primitive

let tuple elements =
  match elements with
  | _ :: _ :: _ -> Ok (Tuple elements)
  | _ -> Error Tuple_requires_two_elements

let nominal ~declaration ~arguments = Nominal { declaration; arguments }
let view t = t
let compare = Stdlib.compare
let equal a b = compare a b = 0

let primitive_to_string = function
  | Unit -> "unit"
  | Bool -> "bool"
  | Char -> "char"
  | Int -> "int"
  | Int32 -> "int32"
  | Int64 -> "int64"
  | Nativeint -> "nativeint"
  | Float -> "float"
  | String -> "string"
  | Bytes -> "bytes"

let rec to_string = function
  | Primitive primitive -> primitive_to_string primitive
  | Tuple elements ->
      elements
      |> List.map to_string
      |> String.concat " * "
      |> Printf.sprintf "(%s)"
  | Nominal { declaration; arguments = [] } -> Identity.to_string declaration
  | Nominal { declaration; arguments } ->
      let arguments = arguments |> List.map to_string |> String.concat ", " in
      Printf.sprintf "(%s) %s" arguments (Identity.to_string declaration)
