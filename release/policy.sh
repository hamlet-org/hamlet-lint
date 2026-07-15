#!/usr/bin/env bash

# shared release-policy helpers. both the local dispatcher and the GitHub
# workflow derive their release rows from this file, so manual dispatch cannot
# select a different Hamlet version, ref, or OCaml matrix.

release_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/current-hamlet.sh
source "${release_here}/current-hamlet.sh"
# shellcheck source=release/versions.sh
source "${release_here}/versions.sh"

release_die() {
  printf '%s\n' "$*" >&2
  exit 2
}

validate_release_policy() {
  if ! [[ "$HAMLET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    release_die "HAMLET_VERSION must be a semantic version: ${HAMLET_VERSION}"
  fi

  if [ "$HAMLET_RELEASE_TAG" != "v${HAMLET_VERSION}" ]; then
    release_die "HAMLET_RELEASE_TAG must be v${HAMLET_VERSION}, got ${HAMLET_RELEASE_TAG}"
  fi

  mapfile -t release_ocaml_patches < <(all_patches)
  if [ "${#release_ocaml_patches[@]}" -eq 0 ]; then
    release_die "release/versions.sh defines no OCaml patches"
  fi
}

resolve_current_hamlet_commit() {
  local resolved

  resolved="$(git ls-remote "$HAMLET_GIT_URL" "refs/tags/${HAMLET_RELEASE_TAG}^{}" \
    | awk 'NR == 1 { print $1; exit }')"
  if [ -z "$resolved" ]; then
    resolved="$(git ls-remote --refs "$HAMLET_GIT_URL" \
      "refs/tags/${HAMLET_RELEASE_TAG}" | awk 'NR == 1 { print $1; exit }')"
  fi

  if ! [[ "$resolved" =~ ^[0-9a-f]{40}$ ]]; then
    release_die "could not resolve Hamlet release tag ${HAMLET_RELEASE_TAG} to a commit"
  fi

  printf '%s\n' "$resolved"
}

release_pairs_json() {
  local hamlet_git_commit=$1
  local pairs='[]'
  local ocaml

  while IFS= read -r ocaml; do
    pairs="$(jq -c \
      --arg hamlet "$HAMLET_VERSION" \
      --arg ocaml "$ocaml" \
      --arg commit "$hamlet_git_commit" \
      '. + [{"hamlet": $hamlet, "ocaml": $ocaml, "hamlet_git_commit": $commit}]' \
      <<< "$pairs")"
  done < <(all_patches)

  printf '%s\n' "$pairs"
}

opam_package_name() {
  printf 'hamlet-subtractor.%s~%s\n' "$HAMLET_VERSION" "$1"
}
