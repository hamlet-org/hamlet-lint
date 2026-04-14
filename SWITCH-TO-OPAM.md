# Bootstrap mode: CI pins hamlet via git

CI installs hamlet with `opam pin` from git because hamlet has not been
released on opam yet. Once `hamlet.X.Y.Z` is on opam-repository, set
`HAMLET_SOURCE: opam` in `.github/workflows/ci.yml` and delete this file.
