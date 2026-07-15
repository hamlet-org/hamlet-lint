(** Compiler-independent payloads carried by generic resolver attachments. *)

type error =
  | Contract_encoding of Generic_contract.serialization_error
  | Contract_decoding of Generic_contract.decode_error
  | Certificate_validation of Effect_certificate.validation_error
  | Malformed_payload of string
  | Contract_digest_mismatch of { expected : string; actual : string }
  | Payload_too_large of { limit : int; actual : int }

val encode_definition : Generic_contract.t -> (string, error) result
val decode_definition : string -> (Generic_contract.t, error) result

val encode_call :
  contract:Generic_contract.t ->
  input:Effect_certificate.t ->
  (string, error) result

val decode_call :
  string -> (Generic_contract.t * Effect_certificate.t, error) result
