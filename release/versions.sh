#!/usr/bin/env bash
# release/versions.sh — supported OCaml patches for hamlet-lint
# releases. Sourced by release/run.sh.
#
# Format: one row per OCaml major.minor line. The first column is the
# major.minor label (organisational only, never used as a version
# string); each following token is a supported patch on that line.
# Patches are full opam version strings: prereleases use the opam tilde
# (e.g. 5.5.0~alpha1, 5.5.0~beta2, 5.5.0~rc1) and sort before the GA
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
# Examples:
#   5.4  5.4.1                       # one GA patch
#   5.4  5.4.1 5.4.2                 # two GA patches on the same line
#   5.5  5.5.0~alpha1 5.5.0~beta1    # prereleases only
#   5.5  5.5.0~rc1 5.5.0             # rc + GA together

OCAML_PATCHES=$(cat <<'EOF'
5.4  5.4.1
EOF
)

# Flatten OCAML_PATCHES into a newline-separated list of patches,
# dropping the major.minor label.
all_patches() {
  awk 'NF >= 2 { for (i = 2; i <= NF; i++) print $i }' <<< "$OCAML_PATCHES"
}
