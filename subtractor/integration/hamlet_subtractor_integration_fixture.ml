open Hamlet

[%%hamlet.service
module type Storage = sig
  type read_error = [ `Local_read_error ]
  type write_error = [ `Local_write_error of string ]

  val run : unit -> (unit, [> read_error | write_error ], 'r) t
end]

[%%hamlet.service
module type Recovery = sig
  type recovery_error = [ `Recovery_error of int ]

  val run : unit -> (unit, [> recovery_error ], 'r) t
end]

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) t
end]

let local_source choose =
  if choose then Combinators.fail `Local_read_error
  else Combinators.fail (`Local_write_error "write")

let local_error choose : (unit, Storage.Errors.write_error, never) t =
  Combinators.catch (local_source choose) ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error -> Combinators.success ()
      | [%hamlet.propagate_e.auto] -> .)

let recovery_error choose :
    ( unit,
      [ Storage.Errors.write_error | Recovery.Errors.recovery_error ],
      never )
    t =
  Combinators.catch (local_source choose) ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error -> Combinators.fail (`Recovery_error 1)
      | [%hamlet.propagate_e.auto] -> .)

let requirement_source =
  let open Combinators in
  let* (_ : Logger.Tag.t) = Logger.Tag.summon in
  let* (_ : Clock.Tag.t) = Clock.Tag.summon in
  success ()

let provide_logger : (unit, never, Clock.Tag.r) t =
  Combinators.provide requirement_source ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness ->
          Logger.Tag.give witness (failwith "logger implementation")
      | [%hamlet.propagate_s.auto] -> .)

let mixed_source choose =
  let open Combinators in
  let* (_ : Logger.Tag.t) = Logger.Tag.summon in
  let* (_ : Clock.Tag.t) = Clock.Tag.summon in
  if choose then fail `Local_read_error else fail (`Local_write_error "write")

let dependent_markers choose : (unit, Storage.Errors.write_error, Clock.Tag.r) t
    =
  Combinators.provide
    (Combinators.catch (mixed_source choose) ~handler:(fun error ->
         match error with
         | #Storage.Errors.read_error -> Combinators.success ()
         | [%hamlet.propagate_e.auto] -> .))
    ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness ->
          Logger.Tag.give witness (failwith "logger implementation")
      | [%hamlet.propagate_s.auto] -> .)

let exhausted_error choose : (unit, never, never) t =
  Combinators.catch (local_source choose) ~handler:(fun error ->
      match error with
      | #Storage.Errors.read_error -> Combinators.success ()
      | #Storage.Errors.write_error -> Combinators.success ()
      | [%hamlet.propagate_e.auto] -> .)
[@@warning "-11"]

let exhausted_requirement : (unit, never, never) t =
  Combinators.provide requirement_source ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness ->
          Logger.Tag.give witness (failwith "logger implementation")
      | #Clock.Tag.r as witness ->
          Clock.Tag.give witness (failwith "clock implementation")
      | [%hamlet.propagate_s.auto] -> .)
[@@warning "-11"]

let cross_cu_error choose :
    ( unit,
      Hamlet_subtractor_cross_cu_fixture.Remote.Errors.write_error,
      never )
    t =
  Combinators.catch (Hamlet_subtractor_cross_cu_fixture.source choose)
    ~handler:(fun error ->
      match error with
      | #Hamlet_subtractor_cross_cu_fixture.Remote.Errors.connect_error ->
          Combinators.success ()
      | #Hamlet_subtractor_cross_cu_fixture.Remote.Errors.read_error ->
          Combinators.success ()
      | [%hamlet.propagate_e.auto] -> .)
