(lang dune 3.14)

(name hamlet-lint)

(generate_opam_files true)

(implicit_transitive_deps false)

(license MIT)

(maintainers "Andrea Simone Costa <andreasimonecosta@gmail.com>")

(authors "Andrea Simone Costa <andreasimonecosta@gmail.com>")

(source
 (github hamlet-org/hamlet-lint))

(homepage "https://github.com/hamlet-org/hamlet-lint")

(bug_reports "https://github.com/hamlet-org/hamlet-lint/issues")

; Dev-time hamlet-lint package metadata.
;
; The generated hamlet-lint.opam file in this repo is what `opam install
; .` and CI use locally. It pins to a SINGLE OCaml minor — the one the
; maintainer is currently developing against — and to a SINGLE hamlet
; version. It is NOT the file that ships to opam-repository.
;
; Release-time opam files are produced from hamlet-lint.opam.tmpl by
; the `release` workflow, which substitutes both a compiler-specific
; OCaml constraint and the exact hamlet version for the package being
; published. Every published package corresponds to one (hamlet,
; ocaml-minor) pair. See README.md for the versioning model.
(package
 (name hamlet-lint)
 (synopsis "Semantic linter for Hamlet")
 (description
  "hamlet-lint is a semantic linter for projects using hamlet. It reads .cmt files produced by the OCaml typechecker and flags stale forwarding arms in row-handler combinators — cases where a handler advertises it can produce a tag the input effect never carries, silently growing the effect's row.")
 (depends
  (ocaml
   (and
    (>= 5.4.1)
    (< 5.4.2)))
  hamlet
  (cppo
   (and
    (>= 1.6.9)
    :build))
  (yojson
   (>= 2.0.0))
  (cmdliner
   (>= 1.1.0))
  (parsexp
   (>= 0.17.0))
  (sexplib0
   (>= 0.17.0))
  (alcotest
   (and
    (>= 1.7.0)
    :with-test))
  (odoc :with-doc)))
