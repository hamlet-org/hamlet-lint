#!/usr/bin/env bash
# validate the release template after replacing every workflow placeholder

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp "${TMPDIR:-/tmp}/hamlet-subtractor-release-opam.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
# shellcheck source=release/current-hamlet.sh
source "${root}/release/current-hamlet.sh"

sed \
  -e 's|%%VERSION%%|0.0.0~5.5.0|g' \
  -e 's|%%OCAML_TARGET%%|5.5.0|g' \
  -e "s|%%HAMLET_VERSION%%|${HAMLET_VERSION}|g" \
  -e 's|%%TARBALL_URL%%|https://example.invalid/hamlet-subtractor.tar.gz|g' \
  -e 's|%%CHECKSUM_SHA256%%|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef|g' \
  "$root/release/hamlet-subtractor.opam.tmpl" > "$temporary"

opam lint "$temporary"

if grep -Eq '%%[A-Z_]+%%' "$temporary"; then
  echo "release template left an unresolved placeholder" >&2
  exit 1
fi

if grep -F 'pin-depends:' "$temporary" >/dev/null; then
  echo "release template must not retain Git pin-depends" >&2
  exit 1
fi

hamlet_dependency="  \"hamlet\" {= \"${HAMLET_VERSION}\"}"
ppx_hamlet_dependency="  \"ppx_hamlet\" {= \"${HAMLET_VERSION}\"}"
if [ "$(grep -Fxc "$hamlet_dependency" "$temporary")" -ne 1 ] \
  || [ "$(grep -Fxc "$ppx_hamlet_dependency" "$temporary")" -ne 1 ]; then
  echo "release template must constrain Hamlet and ppx_hamlet to one exact version" >&2
  exit 1
fi
