(* Caller of both wrappers. The call to [Stale_mod.wrap] passes a concrete
   effect that does not need `Logger — that's the stale path, expected to
   produce a finding. The call to [Clean_mod.wrap] passes an effect that
   does need `Logger — clean, no finding.

   Under the v0.1.1 last-component shortcut, BOTH calls would match BOTH
   latent sites by the bare name "wrap" and produce false findings. *)

open Hamlet.Combinators

let prog_console () : (string, 'e, [> `Console ]) Hamlet.t =
  summon Stale_mod.key `Console

let prog_console_logger () : (string, 'e, [> `Console | `Logger ]) Hamlet.t =
  let* _ = summon Clean_mod.key `Console in
  summon Clean_mod.key `Logger

let main_stale () = Stale_mod.wrap (prog_console ())

let main_clean () = Clean_mod.wrap (prog_console_logger ())
