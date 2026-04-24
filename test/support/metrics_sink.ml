(** Second cross-CU service, in its own file so the multi-service test in
    [test/ppx_rest_cross_cu_test.ml] exercises cross-CU propagate_e across two
    distinct producers in the SAME match. Kept parallel to [remote_cache.ml];
    the include in [hamlet_test_services.ml] re-exports it. *)
[%%hamlet.service
module type MetricsSink = sig
  type ms_backend_down = [ `Ms_backend_down of string ]
  type ms_quota_exceeded = [ `Ms_quota_exceeded of string ]
  type ms_bad_series = [ `Ms_bad_series of string ]
  val record :
    string ->
    float ->
    (unit, [> ms_backend_down | ms_quota_exceeded | ms_bad_series ], 'r) t
end
[@@rest_cross_cu]]
