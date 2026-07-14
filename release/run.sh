#!/usr/bin/env bash
# release/run.sh — dispatch ONE release workflow run that publishes
# every (hamlet, ocaml) pair not yet on opam-repository, bundled into
# a single PR upstream. Tags and GitHub Releases stay 1-per-pair on
# this repo.
#
# Usage:
#   ./release/run.sh <hamlet-version> [hamlet-git-ref]
#
# Policy: only the latest hamlet is supported on new OCaml patches.
# When a new OCaml patch is added to OCAML_PATCHES, re-run this script
# with the latest hamlet version to publish the missing pair(s). Past
# hamlet releases are NOT backfilled. See docs/RELEASING.md §5.
#
# The OCaml axis comes from OCAML_PATCHES in release/versions.sh.
#
# Idempotency. A pair is skipped if its package directory already
# exists on ocaml/opam-repository, or if it is part of any open PR
# touching packages/hamlet-subtractor/. The workflow's `plan` job repeats
# the merged-state check upstream, so a stale dispatch self-corrects.
# Stale tags from a failed run are a separate cleanup
# (`git push origin :v<hamlet>-<ocaml>`, the tag uses `-` because
# git refs forbid `~`).
#
# Requires: gh (authenticated, with read on ocaml/opam-repository and
# workflow-dispatch on hamlet-org/hamlet-subtractor) and jq.

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <hamlet-version> [hamlet-git-ref]" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/versions.sh
source "${here}/versions.sh"

hamlets=("$1")
hamlet_git_url="${HAMLET_GIT_URL:-https://github.com/hamlet-org/hamlet.git}"
hamlet_git_ref="${2:-${HAMLET_GIT_REF:-automatic-propagation-elaboration}}"
mapfile -t patches < <(all_patches)

if [ "${#patches[@]}" -eq 0 ]; then
  echo "release/versions.sh defines no OCaml patches; aborting." >&2
  exit 2
fi

is_git_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

resolve_hamlet_commit() {
  local ref="$1" resolved

  if is_git_commit "$ref"; then
    printf '%s\n' "$ref"
    return
  fi

  resolved="$(git ls-remote "$hamlet_git_url" "${ref}^{}" \
    | awk '$2 ~ /\\^\\{\\}$/ { print $1; exit }')"
  if [ -z "$resolved" ]; then
    resolved="$(git ls-remote --refs "$hamlet_git_url" "$ref" \
      | awk 'NR == 1 { print $1; exit }')"
  fi

  if ! is_git_commit "$resolved"; then
    cat >&2 <<DIAG
could not resolve Hamlet ref '${ref}' to an immutable commit from
${hamlet_git_url}. Supply a reachable branch, tag, or 40-character commit.
DIAG
    exit 2
  fi

  printf '%s\n' "$resolved"
}

hamlet_git_commit="$(resolve_hamlet_commit "$hamlet_git_ref")"
echo "Hamlet release source: ${hamlet_git_url}#${hamlet_git_commit}"

# Merged on opam-repository? One contents API call per pair.
is_published() {
  local pkg="$1"
  gh api \
      -H "Accept: application/vnd.github+json" \
      "repos/ocaml/opam-repository/contents/packages/hamlet-subtractor/hamlet-subtractor.${pkg}" \
      >/dev/null 2>&1
}

# Set of pkg labels currently being introduced by an open PR on
# opam-repository. Bundled PRs may carry several pairs, so we cannot
# search by title; we look at the file paths each open PR touches.
collect_in_flight_pkgs() {
  local prs pr
  prs=$(gh pr list --repo ocaml/opam-repository --state open \
          --search "hamlet-subtractor in:title" \
          --json number --jq '.[].number')
  for pr in $prs; do
    gh pr view "$pr" --repo ocaml/opam-repository --json files \
      --jq '.files[].path' \
      | sed -nE 's|^packages/hamlet-subtractor/hamlet-subtractor\.([^/]+)/opam$|\1|p'
  done | sort -u
}

mapfile -t in_flight < <(collect_in_flight_pkgs)
is_in_flight() {
  local pkg="$1" p
  for p in "${in_flight[@]}"; do
    [ "$p" = "$pkg" ] && return 0
  done
  return 1
}

# Build the JSON pairs list to hand to the workflow. Skip anything
# already merged or in flight; the workflow's `plan` job will re-check
# merged state but cannot see in-flight PRs (no opam-repo PAT in plan).
pairs_json='[]'
queued=0
skipped=0
for hamlet in "${hamlets[@]}"; do
  for ocaml in "${patches[@]}"; do
    pkg="${hamlet}~${ocaml}"

    if is_published "${pkg}"; then
      echo "skip  ${pkg}: already merged on ocaml/opam-repository"
      skipped=$((skipped + 1))
      continue
    fi

    if is_in_flight "${pkg}"; then
      echo "skip  ${pkg}: in an open opam-repository PR"
      skipped=$((skipped + 1))
      continue
    fi

    pairs_json=$(jq -c \
                   --arg h "$hamlet" \
                   --arg o "$ocaml" \
                   --arg c "$hamlet_git_commit" \
                   '. + [{"hamlet":$h,"ocaml":$o,"hamlet_git_commit":$c}]' \
                   <<< "$pairs_json")
    queued=$((queued + 1))
    echo "queue ${pkg}"
  done
done

echo ""
if [ "$queued" -eq 0 ]; then
  echo "nothing to dispatch (queued: 0; skipped: ${skipped})"
  exit 0
fi

echo "dispatching one workflow run for ${queued} pair(s); skipped: ${skipped}"
gh workflow run release.yml -f "pairs=${pairs_json}"
