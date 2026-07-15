#!/usr/bin/env bash
# release/run.sh dispatches the configured current Hamlet release family.
# the GitHub workflow derives one package for each supported OCaml patch and
# bundles the resulting opam files into one upstream PR.
#
# Usage:
#   ./release/run.sh
#
# the workflow is the single authority that resolves the configured release
# tag to a commit for provenance. published opam metadata depends on exact
# Hamlet and PPX package versions, not a Git pin.

set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/policy.sh
source "${here}/policy.sh"

validate_release_policy
echo "dispatching the ${HAMLET_VERSION} release family"
gh workflow run release.yml
