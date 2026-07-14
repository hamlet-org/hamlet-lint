#!/usr/bin/env bash
# validate the release template after replacing every workflow placeholder

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp "${TMPDIR:-/tmp}/hamlet-subtractor-release-opam.XXXXXX")"
trap 'rm -f "$temporary"' EXIT

sed \
  -e 's|%%VERSION%%|0.0.0~5.5.0|g' \
  -e 's|%%OCAML_TARGET%%|5.5.0|g' \
  -e 's|%%TARBALL_URL%%|https://example.invalid/hamlet-subtractor.tar.gz|g' \
  -e 's|%%CHECKSUM_SHA256%%|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef|g' \
  "$root/release/hamlet-subtractor.opam.tmpl" > "$temporary"

opam lint "$temporary"
