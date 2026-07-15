#!/usr/bin/env bash

# validate the static release-policy contract without contacting GitHub.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release/policy.sh
source "${root}/release/policy.sh"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

validate_release_policy

expected_tag="v${HAMLET_VERSION}"
[ "$HAMLET_RELEASE_TAG" = "$expected_tag" ] ||
  fail "current Hamlet release tag does not match its version"

expected_ocaml="$(all_patches)"
actual_ocaml="$(release_pairs_json 0123456789abcdef0123456789abcdef01234567 \
  | jq -r '.[].ocaml')"
[ "$actual_ocaml" = "$expected_ocaml" ] ||
  fail "release pairs do not use exactly the supported OCaml patches"

if "${root}/release/run.sh" unexpected >/dev/null 2>&1; then
  fail "release dispatcher accepted an arbitrary release argument"
fi

workflow_dispatch=$(sed -n '/^  workflow_dispatch:/,/^permissions:/p' \
  "${root}/.github/workflows/release.yml")
if grep -Eq '^ +pairs:' <<< "$workflow_dispatch"; then
  fail "release workflow still accepts caller-supplied release pairs"
fi

grep -F 'source release/policy.sh' "${root}/.github/workflows/release.yml" >/dev/null ||
  fail "release workflow does not derive pairs from the shared policy"
grep -F '"hamlet.${HAMLET_VERSION}" "ppx_hamlet.${HAMLET_VERSION}"' \
  "${root}/.github/workflows/release.yml" >/dev/null ||
  fail "release workflow does not install the configured published Hamlet packages"
