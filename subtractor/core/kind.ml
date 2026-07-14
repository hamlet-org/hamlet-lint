type t = Error | Requirement

let compare = Stdlib.compare
let equal a b = compare a b = 0
let to_string (kind : t) =
  match kind with Error -> "error" | Requirement -> "requirement"

let explicit_fallback (kind : t) =
  match kind with Error -> "%hamlet.te ..." | Requirement -> "%hamlet.ts ..."
