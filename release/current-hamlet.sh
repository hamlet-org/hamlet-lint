#!/usr/bin/env bash

# the only Hamlet release family supported by newly published Subtractor
# packages. advance these two values together after Hamlet publishes its next
# release. older Subtractor packages remain available but are not backfilled
# for new OCaml compiler patches.
HAMLET_VERSION="0.1.0"
HAMLET_RELEASE_TAG="v0.1.0"
HAMLET_GIT_URL="https://github.com/hamlet-org/hamlet.git"
