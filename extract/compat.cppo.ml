(** Compiler-libs compatibility firewall.

    All accesses to [Types.*] / [Typedtree.*] / [Path.*] / [Cmt_format.*] shapes
    that may drift across OCaml minors should go through this file. When a
    5.x → 5.(x+1) transition breaks something, patch this single file: add a
    [#if OCAML_VERSION >= (5, 5, 0)] branch around the affected body.

    This file is preprocessed by [cppo] (see sibling [dune]) with
    [-V OCAML:%{ocaml_version}], producing [compat.ml] in the build dir.
    Currently supports OCaml 5.4.1 exactly; the guard below is the
    enforcement.

    The PoC the linter is ported from (hamlet PR #9, [lint_poc/bin/poc.ml])
    used 5.4.1 APIs directly — [Types.row_fields], [Types.row_more],
    [Types.row_field_repr], [Tparam_pat], [Tfunction_cases], [Tfunction_body],
    [Tparam_optional_default]. None of these are guaranteed stable, hence
    the firewall. *)

#if OCAML_VERSION < (5, 4, 1) || OCAML_VERSION >= (5, 5, 0)
#error "hamlet-lint currently supports only OCaml 5.4.1"
#endif
