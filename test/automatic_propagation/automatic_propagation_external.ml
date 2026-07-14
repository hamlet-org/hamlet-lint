open Hamlet

let ( let* ) = Combinators.( let* )

[%%hamlet.service
module type Storage = sig
  type storage_missing = [ `Storage_missing of string ]
  type storage_timeout = [ `Storage_timeout of string ]
  type storage_unavailable = [ `Storage_unavailable of string ]
  type storage_corrupt = [ `Storage_corrupt of string ]

  val read :
    string ->
    ( string,
      [> storage_missing
      | storage_timeout
      | storage_unavailable
      | storage_corrupt ],
      'r )
    t
end
[@@rest_cross_cu]]

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, [> ], 'r) t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, [> ], 'r) t
end]

[%%hamlet.service
module type Provision = sig
  type provision_error = [ `Provision_error of string ]
  type provision_fallback = [ `Provision_fallback ]

  val fetch : unit -> (string, [> provision_error | provision_fallback ], 'r) t
end]
[@@rest_cross_cu]

[%%hamlet.service
module type Linear = sig
  type e1 = [ `Linear_e1 ]
  type e2 = [ `Linear_e2 ]
  type e3 = [ `Linear_e3 ]
  type e4 = [ `Linear_e4 ]
  type e5 = [ `Linear_e5 ]
  type e6 = [ `Linear_e6 ]
  type e7 = [ `Linear_e7 ]
  type e8 = [ `Linear_e8 ]
  type e9 = [ `Linear_e9 ]
  type e10 = [ `Linear_e10 ]
  type e11 = [ `Linear_e11 ]
  type e12 = [ `Linear_e12 ]
  type e13 = [ `Linear_e13 ]
  type e14 = [ `Linear_e14 ]
  type e15 = [ `Linear_e15 ]
  type e16 = [ `Linear_e16 ]

  val run :
    unit ->
    ( unit,
      [> e1
      | e2
      | e3
      | e4
      | e5
      | e6
      | e7
      | e8
      | e9
      | e10
      | e11
      | e12
      | e13
      | e14
      | e15
      | e16 ],
      'r )
    t
end
[@@rest_cross_cu]]

let storage_program : (string, Storage.Errors.error, Storage.Tag.r) Hamlet.t =
  let* (module Storage) = Storage.Tag.summon in
  Storage.read "item"

let requirement_program :
    (string, Hamlet.never, [ Logger.Tag.r | Clock.Tag.r ]) Hamlet.t =
  let* _logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  Hamlet.Combinators.return "ready"

let provision_program :
    (string, Provision.Errors.error, Provision.Tag.r) Hamlet.t =
  let* (module Provision) = Provision.Tag.summon in
  Provision.fetch ()

let linear_program : (unit, Linear.Errors.error, Linear.Tag.r) Hamlet.t =
  let* (module Linear) = Linear.Tag.summon in
  Linear.run ()
