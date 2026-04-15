#!/usr/bin/env bash
# release/versions.sh — supported OCaml patches for hamlet-lint
# releases. Sourced by release/run.sh.
#
# Format: one row per OCaml major.minor line. Column 1 is the
# major.minor prefix; each following token is a patch suffix that
# gets concatenated as `<major.minor>.<suffix>` to form the full
# patch. Suffixes are GA patch numbers (1, 2, ...) or opam-style
# prereleases (0~alpha1, 0~beta2, 0~rc1) which sort before the GA
# release as opam expects.
#
# Why patches and not minors: extract/compat.cppo.ml's #error guard
# pins the exact patch, so the build artifact is patch-specific and
# the opam ocaml constraint is `{= "<patch>"}`.
#
# Mirror any add/remove with: .github/workflows/ci.yml (matrix),
# .github/workflows/release.yml (choice list), extract/compat.cppo.ml
# (#if guard), dune-project ((ocaml ...)).
#
# Examples (suffix → full patch):
#   5.4  1                  → 5.4.1
#   5.4  1 2                → 5.4.1, 5.4.2
#   5.5  0~alpha1 0~beta1   → 5.5.0~alpha1, 5.5.0~beta1
#   5.5  0~rc1 0            → 5.5.0~rc1, 5.5.0

OCAML_PATCHES=$(cat <<'EOF'
5.4  1
EOF
)

# Flatten OCAML_PATCHES into a newline-separated list of full patches,
# joining each suffix to its row's major.minor prefix.
all_patches() {
  awk 'NF >= 2 { for (i = 2; i <= NF; i++) print $1 "." $i }' <<< "$OCAML_PATCHES"
}
