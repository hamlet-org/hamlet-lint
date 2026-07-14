open Hamlet

let fail = Combinators.fail
let return = Combinators.return

module Errors = struct
  type a = [ `A ]
  type b = [ `B of string ]
  type error = [ a | b ]
end

module Logger_live = Automatic_propagation_external.Logger.Make (struct
  let log _ = return ()
end)

type storage_subset =
  [ Automatic_propagation_external.Storage.Errors.storage_missing
  | Automatic_propagation_external.Storage.Errors.storage_timeout ]

let subset_source : (string, storage_subset, never) t =
  fail (`Storage_timeout "slow" : storage_subset)

let exact_source : (string, Errors.error, never) t = fail (`A : Errors.error)

let case_ref_full =
  Automatic_propagation_external.storage_program
  |> Combinators.catch
       ~handler:(fun
           (error : [%hamlet.te Automatic_propagation_external.Storage]) ->
         match error with
         | #Automatic_propagation_external.Storage.Errors.storage_missing ->
             return "missing"
         | [%hamlet.propagate_e] -> .)

let case_ref_subset =
  Combinators.catch subset_source
    ~handler:(fun
        (error :
          [%hamlet.te
            Automatic_propagation_external.Storage.Errors.storage_missing,
            Automatic_propagation_external.Storage.Errors.storage_timeout])
      ->
      match error with
      | #Automatic_propagation_external.Storage.Errors.storage_missing ->
          return "missing"
      | [%hamlet.propagate_e] -> .)

let case_ref_recovery =
  Combinators.catch exact_source
    ~handler:(fun (error : [%hamlet.te Errors.a, Errors.b]) ->
      match error with
      | #Errors.a -> fail `Recovery_error
      | [%hamlet.propagate_e] -> .)

let case_ref_exhausted =
  Combinators.catch exact_source
    ~handler:(fun (error : [%hamlet.te Errors.a, Errors.b]) ->
      (match error with
      | #Errors.a -> return "a"
      | #Errors.b -> return "b"
      | [%hamlet.propagate_e] -> .)
      [@warning "-11"])

let case_ref_requirement =
  Combinators.provide
    ~handler:(fun
        (requirement :
          [%hamlet.ts
            Automatic_propagation_external.Logger,
            Automatic_propagation_external.Clock])
      ->
      match requirement with
      | #Automatic_propagation_external.Logger.Tag.r as witness ->
          Automatic_propagation_external.Logger.Tag.give witness
            (module Logger_live)
      | [%hamlet.propagate_s] -> .)
    Automatic_propagation_external.requirement_program
