(** A source range with both byte offsets and user-facing line and column
    coordinates. All coordinates refer to the same source buffer. *)
type t

type validation_error =
  | Empty_file
  | Invalid_start_offset of int
  | Invalid_end_offset of int
  | End_before_start of { start_offset : int; end_offset : int }
  | Invalid_start_line of int
  | Invalid_end_line of int
  | Invalid_start_column of int
  | Invalid_end_column of int
  | End_position_before_start of {
      start_line : int;
      start_column : int;
      end_line : int;
      end_column : int;
    }

val make :
  file:string ->
  start_offset:int ->
  end_offset:int ->
  start_line:int ->
  start_column:int ->
  end_line:int ->
  end_column:int ->
  (t, validation_error) result

val file : t -> string
val start_offset : t -> int
val end_offset : t -> int
val start_line : t -> int
val start_column : t -> int
val end_line : t -> int
val end_column : t -> int
val compare : t -> t -> int
val equal : t -> t -> bool
