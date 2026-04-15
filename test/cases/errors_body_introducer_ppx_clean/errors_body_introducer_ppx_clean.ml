(* Fixture: arm body invokes a PPX-shaped [<Mod>.Errors.make_<name>]
   constructor. We emulate the PPX output by hand (no dependency on
   [hamlet_test_services]) — the walker only pattern-matches on the
   [Pdot(Pdot(_, "Errors"), "make_...")] path shape, not on how the
   module was produced. *)

open Hamlet.Combinators

module Foo = struct
  module Errors = struct
    let make_foo_error (s : string) : [> `Foo_error of string ] = `Foo_error s
  end
end

let prog () : (int, [> `Start ], 'r) Hamlet.t = failure `Start

let _use () =
  catch (prog ()) ~f:(function `Start ->
      failure (Foo.Errors.make_foo_error "boom"))
