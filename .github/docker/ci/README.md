# Hamlet Subtractor CI Image

The main CI workflow publishes this Linux dependency image to GitHub Container
Registry as `ghcr.io/<owner>/<repo>-ci`.

It contains an OCaml 5.5.0 switch, the project development dependencies, and
the exact `hamlet` and `ppx_hamlet` source revision resolved by the workflow.
The two packages are always pinned to the same commit.

## Image identity

The `deps-<hash>` tag is computed from the root Dune and opam metadata, this
Dockerfile, the OCaml compiler version, and both the Hamlet URL and resolved
commit. Resolving `main` to a commit before hashing is essential: treating a
moving branch name as the cache identity could otherwise reuse an image with a
different Typedtree or PPX implementation.

Main branch runs publish `main`, `sha-<head>`, and `deps-<hash>` tags. Same
repository pull requests publish their matching `deps-<hash>` tag plus
pull-request tags. Fork pull requests cannot publish packages, so they use the
trusted `main` image and install the source pin again in the direct jobs that
need it.

## CI use

`build-ubuntu` and `quality` consume the resolved image through GitHub Actions
container jobs. The direct minimum-Dune and optional macOS jobs repeat the
same exact dual package pin before installing dependencies. This keeps all
paths consistent even though only Linux uses Docker.
