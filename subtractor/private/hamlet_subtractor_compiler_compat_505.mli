(** Private OCaml 5.5 compiler-libs adapter for incomplete row observations.
    Exact proof conversion belongs to the subtraction probe and must perform
    stronger closure, provenance, and identity checks. *)
val present_variant_labels : Types.type_expr -> string list
