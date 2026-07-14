# syntax=docker/dockerfile:1

FROM ubuntu:24.04

ARG OCAML_VERSION=5.5.0
ARG OPAM_VERSION=2.5.1
ARG HAMLET_GIT_COMMIT

ENV DEBIAN_FRONTEND=noninteractive \
    OPAMROOT=/opt/opam \
    OPAMROOTISOK=true \
    OPAMYES=true \
    OPAMCONFIRMLEVEL=unsafe-yes \
    PATH=/opt/opam/ci/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential \
      bubblewrap \
      ca-certificates \
      curl \
      git \
      m4 \
      openssl \
      pkg-config \
      rsync \
      unzip \
      zstd \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://opam.ocaml.org/install.sh -o /tmp/opam-install.sh \
    && cd /tmp \
    && sh opam-install.sh --download-only --version "${OPAM_VERSION}" \
    && install -m 0755 "opam-${OPAM_VERSION}-x86_64-linux" /usr/local/bin/opam \
    && rm -f /tmp/opam-install.sh "/tmp/opam-${OPAM_VERSION}-x86_64-linux"

RUN opam init --bare --disable-sandboxing \
    && opam update \
    && opam switch create ci "ocaml-base-compiler.${OCAML_VERSION}"

WORKDIR /workspace

COPY dune-project ./*.opam ./
COPY hamlet-source /opt/hamlet-source

# Pin both packages to the checked-out companion source. The workflow resolves
# this tree once, includes its commit in the image key, and never gives the
# Docker build an authenticated remote URL or token.
RUN test -n "${HAMLET_GIT_COMMIT}" \
    && opam pin add -y --no-action hamlet /opt/hamlet-source \
    && opam pin add -y --no-action ppx_hamlet /opt/hamlet-source \
    && opam install --switch=ci -y hamlet ppx_hamlet \
    && opam install --switch=ci -y . --deps-only --with-test --with-doc --with-dev-setup \
    && opam clean --all

ENV OPAMSWITCH=ci

CMD ["bash"]
