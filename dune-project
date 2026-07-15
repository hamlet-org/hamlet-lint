(lang dune 3.18)

(using dune_site 0.1)

(name hamlet-subtractor)

(generate_opam_files true)

(implicit_transitive_deps false)

(license MIT)

(maintainers "Andrea Simone Costa <andreasimonecosta@gmail.com>")

(authors "Andrea Simone Costa <andreasimonecosta@gmail.com>")

(source
 (github hamlet-org/hamlet-subtractor))

(homepage "https://github.com/hamlet-org/hamlet-subtractor")

(bug_reports "https://github.com/hamlet-org/hamlet-subtractor/issues")

; Development metadata targets the current compiler API. The release template
; publishes one package for each supported (Hamlet, OCaml patch) pair, where
; both the Hamlet packages and compiler version are exact constraints.
(package
 (name hamlet-subtractor)
 (sites
  (libexec resolver))
 (synopsis "Exact automatic propagation for Hamlet")
 (description
  "Compiler-assisted automatic propagation for Hamlet. The package installs hamlet-subtractor.ppx together with its matching compiler-libs resolver.")
 (depends
  (ocaml
   (= 5.5.0))
  (dune
   (>= 3.18))
  hamlet
  ppx_hamlet
  (ppxlib
   (>= 0.38.0))
  dune-site
  (yojson
   (>= 2.0.0))
  (alcotest
   (and
    (>= 1.7.0)
    :with-test))
  (merlin :with-test)
  (ocaml-lsp-server :with-test)
  (fmt
   (and
    (>= 0.11.0)
    :with-test))
  (odoc :with-doc)
  (ocamlformat
   (and
    (= 0.29.0)
    :with-dev-setup))))
