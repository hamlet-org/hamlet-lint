(** Polymorphic-variant row inspection.

    All [type_expr] shapes the linter cares about boil down to a [Tvariant]: the
    handler's declared [%hamlet.te ...] universe and upstream's effect row. This
    module exposes the two operations the rest of the linter needs:

    - {!variant_tags}: every tag in the row with its presence state.
    - {!present_tags}: only the tags reachable from this row (i.e. with
      [Rpresent] or [Reither] field repr — both count as "the row can carry this
      tag").

    [Reither] counts as present here because in our context it means the tag is
    structurally part of the type even when conjunctive constraints have not yet
    fully resolved it. The linter is only interested in whether a tag is
    reachable, not in whether it has been proven mandatory. *)

open Types

(** Walk a row's fields and chase its [row_more] tail. Returns the list of
    [(tag, presence)] pairs across the entire row. Non-variant types yield [[]].
*)
let rec variant_tags (ty : type_expr) : (string * [ `Present | `Absent ]) list =
  let ty = Ctype.expand_head Env.empty ty in
  match Types.get_desc ty with
  | Tvariant row ->
      let fields = Types.row_fields row in
      let more = Types.row_more row in
      let from_fields =
        List.filter_map
          (fun (tag, field) ->
            match Types.row_field_repr field with
            | Rpresent _ | Reither (_, _, _) -> Some (tag, `Present)
            | Rabsent -> Some (tag, `Absent))
          fields
      in
      from_fields @ variant_tags more
  | _ -> []

(** Just the tag names reachable from this row, in declaration order. *)
let present_tags (ty : type_expr) : string list =
  List.filter_map
    (fun (tag, st) -> match st with `Present -> Some tag | _ -> None)
    (variant_tags ty)
