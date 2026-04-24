(** [%%hamlet.service ... end [@@rest_cross_cu]] service in its own file so the
    cross-CU tests in [test/ppx_rest_cross_cu_test.ml] exercise the real
    cross-CU propagate_e path: the PPX run on that file has no entry for
    [RemoteCache] in its local [service_errors] table and must resolve the rest
    arm via the producer's generated [__Hamlet_rest_RemoteCache__] module. Keep
    this file separate from [hamlet_test_services.ml]; that file [include]s this
    one at the end. *)
[%%hamlet.service
module type RemoteCache = sig
  type rc_miss = [ `Rc_miss of string ]
  type rc_timeout = [ `Rc_timeout of string ]
  type rc_unavailable = [ `Rc_unavailable of string ]
  type rc_corrupt = [ `Rc_corrupt of string ]
  val get :
    string ->
    (string, [> rc_miss | rc_timeout | rc_unavailable | rc_corrupt ], 'r) t
  val put : string -> string -> (unit, [> rc_timeout | rc_unavailable ], 'r) t
end
[@@rest_cross_cu]]
