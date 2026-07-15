# Automatic propagation acceptance harness

This directory exercises automatic propagation through public Hamlet and Dune
interfaces from an uninstalled checkout. Positive fixtures use
`staged_pps hamlet-subtractor.ppx`; external services are compiled in separate units
so catalogue resolution must cross a real CMI boundary.

The positive raw-Merlin fixture also declares
`(preprocessor_deps (package hamlet-subtractor))`. That repository-only edge builds
the local resolver before an editor query. The PPX finds it beside its own
`.ppx` directory in the same Dune build context. Installed consumers do not
need this edge and resolve the executable through the `hamlet-subtractor` Dune site.

`automatic_propagation_type_reference.ml` keeps representative explicit `%hamlet.te` and
`%hamlet.ts` fallbacks compiling and provides reference rows for auditing the
automatic type golden without substituting for automatic elaboration. The
named acceptance alias depends on its final CMT.

`dune runtest test/automatic_propagation` runs the complete acceptance gate:
the final CMT type golden, runtime cases, saved and unsaved OCaml-LSP hovers,
raw Merlin preprocessing and Typedtree checks, dependency invalidation,
refusal diagnostics, and the linear `Errors.Cases` guard. The type golden
records every result, error, and requirement row exposed by bindings named
`case_*`.

The Dune action keeps raw Merlin on Dune's default editor context. It runs the
mutable dependency and negative-fixture checks in a separate acceptance build
directory, so the outer test action never competes for its build lock. It
requires the `ocamlmerlin` and `ocamllsp` executables from the active opam
switch.

`dune build @test/automatic_propagation/automatic-propagation-acceptance` is an
explicit name for the same complete gate. Running
`test/automatic_propagation/run_acceptance.sh` directly also runs it, including
the OCaml-LSP session.

The committed expansion golden must always come from the raw Merlin output of
the final implementation. Do not create it from explicit `%hamlet.te` or
`%hamlet.ts` stand-ins.

The normal `dune runtest` gate also runs the installed-consumer package test.
It installs Hamlet Subtractor into a fresh prefix, runs a separate repository with only
`(staged_pps hamlet-subtractor.ppx)`, traces the Dune-site resolver, and verifies
narrow raw Merlin hover without source-tree metadata.

`make installed-consumer` runs that same package proof directly. Use
`make installed-consumer-keep` when investigating the external fixture.
It runs the same gate with `KEEP_WORK=1`, preserves the temporary directory,
and prints the consumer project, installation prefix, and generated
`with-installed-hamlet-subtractor` launcher paths before exiting. The launcher derives the
private prefix from its own location, prepends its library directory to
`OCAMLPATH`, selects the same Dune and OCaml toolchain that built the fixture,
and runs any requested command. This prevents a GUI editor from reading a
Merlin configuration written by a different Dune version. Terminal tools can
be invoked through it directly. Keep mode prints copyable commands for VS Code,
Vim, Emacs, and a shell rooted in the consumer project. These are examples for
tools already installed on the machine. The generated consumer contains
`.vscode/settings.json`: it selects Hamlet Subtractor's local opam switch and supplies the
private `OCAMLPATH` to OCaml-LSP. The normal VS Code process can therefore open
the consumer normally, with no separate profile, process restart, or inherited
environment requirement. Before using the Emacs command, quit all running
instances and stop any editor daemon. The launcher cannot change the
environment of an editor process that is already running.

The output also includes a quoted cleanup command. Close the editor first, then
run that command when the fixture is no longer needed. Preserved fixtures are
not delegated to operating-system temporary-directory cleanup.
