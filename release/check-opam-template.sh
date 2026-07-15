#!/usr/bin/env bash
# validate the release template after replacing every workflow placeholder

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp "${TMPDIR:-/tmp}/hamlet-subtractor-release-opam.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
hamlet_git_commit="0123456789abcdef0123456789abcdef01234567"

sed \
  -e 's|%%VERSION%%|0.0.0~5.5.0|g' \
  -e 's|%%OCAML_TARGET%%|5.5.0|g' \
  -e "s|%%HAMLET_GIT_COMMIT%%|${hamlet_git_commit}|g" \
  -e 's|%%TARBALL_URL%%|https://example.invalid/hamlet-subtractor.tar.gz|g' \
  -e 's|%%CHECKSUM_SHA256%%|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef|g' \
  "$root/release/hamlet-subtractor.opam.tmpl" > "$temporary"

opam lint "$temporary"

if grep -Eq '%%[A-Z_]+%%' "$temporary"; then
  echo "release template left an unresolved placeholder" >&2
  exit 1
fi

pin="git+https://github.com/hamlet-org/hamlet.git#${hamlet_git_commit}"
if [ "$(grep -Fc "$pin" "$temporary")" -ne 2 ]; then
  echo "release template must pin Hamlet and ppx_hamlet to one immutable commit" >&2
  exit 1
fi
