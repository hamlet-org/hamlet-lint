# hamlet-subtractor development workflow.
#
# Usage:
#   make <target>              run one target
#   make <target> PROMOTE=1    run and promote generated diffs
#   make all                   run the full local CI contract
#
# Targets:
#   build                      build all targets
#   test                       run all unit, Cram, Merlin, and LSP tests
#   installed-consumer         verify an isolated installed consumer and hover
#   installed-consumer-keep    preserve that temporary consumer for inspection
#   fmt                        check formatting
#   fmt-fix                    apply formatting
#   doc                        build documentation
#   opam                       lint package metadata
#   all                        build, test, format, docs, opam

DUNE := opam exec -- dune
PROMOTE ?= 0
OCAML_VERSION ?= 5.5.0
HAMLET_GIT_URL ?= https://github.com/hamlet-org/hamlet.git
HAMLET_GIT_REF ?= automatic-propagation-elaboration

.PHONY: all setup deps build test fmt fmt-fix doc opam clean promote watch help installed-consumer installed-consumer-keep _maybe_promote
.DEFAULT_GOAL := help

help:
	@sed -n '2,17p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

setup:
	opam switch create . --empty --yes
	opam pin add --no-action --yes hamlet "$(HAMLET_GIT_URL)#$(HAMLET_GIT_REF)"
	opam pin add --no-action --yes ppx_hamlet "$(HAMLET_GIT_URL)#$(HAMLET_GIT_REF)"
	opam install --yes ocaml-base-compiler.$(OCAML_VERSION)
	$(MAKE) --no-print-directory deps
	git config core.hooksPath .githooks

deps:
	opam install . --deps-only --with-test --with-doc --with-dev-setup

build:
	$(DUNE) build
	@$(MAKE) --no-print-directory _maybe_promote

test:
	$(DUNE) runtest --force
	@$(MAKE) --no-print-directory _maybe_promote

fmt:
	$(DUNE) build @fmt
	@$(MAKE) --no-print-directory _maybe_promote

fmt-fix:
	$(DUNE) fmt --auto-promote

doc:
	$(DUNE) build @doc

opam:
	opam lint hamlet-subtractor.opam
	./release/check-opam-template.sh

installed-consumer:
	opam exec -- ./subtractor/integration/installed_consumer.sh

installed-consumer-keep:
	KEEP_WORK=1 $(MAKE) --no-print-directory installed-consumer

all: build test fmt doc opam

clean:
	$(DUNE) clean

promote:
	$(DUNE) promote

watch:
	$(DUNE) build --watch

_maybe_promote:
	@if [ "$(PROMOTE)" = "1" ]; then $(DUNE) promote || true; fi
