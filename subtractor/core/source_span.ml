type t = {
  file : string;
  start_offset : int;
  end_offset : int;
  start_line : int;
  start_column : int;
  end_line : int;
  end_column : int;
}

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

let make
    ~file
    ~start_offset
    ~end_offset
    ~start_line
    ~start_column
    ~end_line
    ~end_column =
  if String.trim file = "" then Error Empty_file
  else if start_offset < 0 then Error (Invalid_start_offset start_offset)
  else if end_offset < 0 then Error (Invalid_end_offset end_offset)
  else if end_offset < start_offset then
    Error (End_before_start { start_offset; end_offset })
  else if start_line < 1 then Error (Invalid_start_line start_line)
  else if end_line < 1 then Error (Invalid_end_line end_line)
  else if start_column < 0 then Error (Invalid_start_column start_column)
  else if end_column < 0 then Error (Invalid_end_column end_column)
  else if
    end_line < start_line || (end_line = start_line && end_column < start_column)
  then
    Error
      (End_position_before_start
         { start_line; start_column; end_line; end_column })
  else
    Ok
      {
        file;
        start_offset;
        end_offset;
        start_line;
        start_column;
        end_line;
        end_column;
      }

let file t = t.file
let start_offset t = t.start_offset
let end_offset t = t.end_offset
let start_line t = t.start_line
let start_column t = t.start_column
let end_line t = t.end_line
let end_column t = t.end_column
let compare = Stdlib.compare
let equal a b = compare a b = 0
