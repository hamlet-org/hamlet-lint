#!/usr/bin/env bash
# release/run.sh — dispatch the release workflow for every (hamlet,
# ocaml) pair not yet on opam-repository.
#
# Usage:
#   ./release/run.sh 0.1.0           # one hamlet version
#   ./release/run.sh 0.1.0 0.2.0     # backfill several hamlet versions
#
# At least one hamlet version is required: a release always names an
# explicit hamlet, no "current main" default. The OCaml axis comes
# entirely from OCAML_PATCHES in release/versions.sh.
#
# Idempotency: a pair is skipped if its package directory already
# exists on ocaml/opam-repository, or if an open PR titled
# "hamlet-lint <pair>" is already up. Local git state is not consulted
# — a stale tag from a failed run is a separate cleanup
# (`git push origin :v<pair>`).
#
# Requires: gh (authenticated, with read on ocaml/opam-repository and
# workflow-dispatch on hamlet-org/hamlet-lint) and jq.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <hamlet-version> [<hamlet-version> ...]" >&2
  echo "       (at least one hamlet version is required; no default)" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/versions.sh
source "${here}/versions.sh"

hamlets=("$@")
mapfile -t patches < <(all_patches)

if [ "${#patches[@]}" -eq 0 ]; then
  echo "release/versions.sh defines no OCaml patches; aborting." >&2
  exit 2
fi

# Merged on opam-repository? One contents API call per pair.
is_published() {
  local pkg="$1"
  gh api \
      -H "Accept: application/vnd.github+json" \
      "repos/ocaml/opam-repository/contents/packages/hamlet-lint/hamlet-lint.${pkg}" \
      >/dev/null 2>&1
}

# Open PR on opam-repository titled "hamlet-lint <pair>"?
has_open_pr() {
  local pkg="$1"
  local count
  count=$(gh pr list --repo ocaml/opam-repository --state open \
            --search "hamlet-lint ${pkg} in:title" \
            --json number | jq 'length')
  [ "$count" -gt 0 ]
}

dispatched=0
skipped=0
for hamlet in "${hamlets[@]}"; do
  for ocaml in "${patches[@]}"; do
    pkg="${hamlet}-${ocaml}"

    if is_published "${pkg}"; then
      echo "skip  ${pkg}: already merged on ocaml/opam-repository"
      skipped=$((skipped + 1))
      continue
    fi

    if has_open_pr "${pkg}"; then
      echo "skip  ${pkg}: open PR already on ocaml/opam-repository"
      skipped=$((skipped + 1))
      continue
    fi

    echo "run   ${pkg}"
    gh workflow run release.yml \
      -f "hamlet_version=${hamlet}" \
      -f "ocaml_target=${ocaml}"
    dispatched=$((dispatched + 1))
  done
done

echo ""
echo "dispatched: ${dispatched}; skipped: ${skipped}"
