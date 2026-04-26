# hamlet-lint dev workflow. Wraps dune so local and CI runs share the
# same entry point, plus shortcuts for running the linter on individual
# fixtures without having to remember long paths.
#
# Usage:
#   make <target>              # run one target
#   make <target> PROMOTE=1    # run and then `dune promote` any diffs
#   make <target> FIXTURE=<n>  # fixture-scoped targets below
#   make all                   # everything CI runs: build + test + fmt + doc + opam
#
# Targets:
#   build      plain `dune build`
#   clean      `dune clean`
#   watch      `dune build --watch` — rebuild on file changes (Ctrl-C to stop)
#   test       `dune runtest` (alcotest suites + e2e fixtures)
#   fmt        dune fmt check (use PROMOTE=1 to rewrite files)
#   fmt-fix    auto-format the whole project in place
#   doc        `dune build @doc` (odoc warnings become errors via dune)
#   opam       opam lint on hamlet-lint.opam
#   promote    run `dune promote` on its own
#   all        build + test + fmt + doc + opam
#   setup      one-time dev setup: install deps + enable git hooks
#   hooks      enable the repo's pre-commit hook in your local clone
#   list       list available fixture names under test/cases/
#   paths      print resolved paths (debugging Makefile vars)
#
# Fixture-scoped targets (require FIXTURE=<name>):
#   run        run linter on one fixture, pretty report (exit 1 on findings)
#   warn       same as run but always exits 0 (analyzer --warn-only)
#   ndjson     show the canonical ND-JSON the extractor emits
#   debug      run with HAMLET_LINT_DEBUG=1 to see walker skips

DUNE       := opam exec -- dune
PROMOTE    ?= 0
FIXTURE    ?=

# Anchor every path to the directory containing THIS Makefile, so that
# the targets still work when make is invoked from a subdirectory.
REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  := $(REPO_ROOT)/_build/default
CASES_DIR  := $(REPO_ROOT)/test/cases
EXTRACT    := $(BUILD_DIR)/extract/main.exe
ANALYZE    := $(BUILD_DIR)/analyzer/main.exe

# Fixtures live in a single dune library (`hamlet_lint_fixtures`) with
# one module per file under test/cases/*.ml. Dune mangles the cmt as
# `hamlet_lint_fixtures__<Cap>.cmt` under
# `_build/default/test/cases/.hamlet_lint_fixtures.objs/byte/`.
# Capitalise the first letter of $(FIXTURE) at target-evaluation time
# so `run FIXTURE=widening_cases` finds Widening_cases.cmt. Portable
# cut+tr rather than sed '\U' (GNU-only, breaks on BSD sed / macOS).
FIXTURE_HEAD = $(shell echo "$(FIXTURE)" | cut -c1 | tr '[:lower:]' '[:upper:]')
FIXTURE_TAIL = $(shell echo "$(FIXTURE)" | cut -c2-)
FIXTURE_CAP  = $(FIXTURE_HEAD)$(FIXTURE_TAIL)
CASE_CMT     = $(BUILD_DIR)/test/cases/.hamlet_lint_fixtures.objs/byte/hamlet_lint_fixtures__$(FIXTURE_CAP).cmt

.PHONY: help build clean watch test fmt fmt-fix doc opam promote all setup hooks list paths \
        run warn ndjson debug _require_fixture _maybe_promote

.DEFAULT_GOAL := help

help:
	@sed -n '2,31p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

build:
	$(DUNE) build
	@$(MAKE) --no-print-directory _maybe_promote

clean:
	$(DUNE) clean

# Incremental rebuild on file changes. Dune's built-in --watch uses
# inotify (linux) / fsevents (macos); Ctrl-C to stop.
watch:
	$(DUNE) build --watch

test: build
	$(DUNE) runtest --force
	@$(MAKE) --no-print-directory _maybe_promote

fmt:
	$(DUNE) build @fmt
	@$(MAKE) --no-print-directory _maybe_promote

fmt-fix:
	$(DUNE) build @fmt --auto-promote

doc:
	$(DUNE) build @doc

opam:
	opam lint hamlet-lint.opam

promote:
	$(DUNE) promote

all: build test fmt doc opam

# One-time dev environment setup. Installs dependencies and enables
# the pre-commit hook. Run this once after cloning.
setup: hooks
	opam install . --deps-only --with-dev-setup --with-test --with-doc -y
	@echo "setup complete — deps installed, hooks enabled"

# Enable the pre-commit hook that runs `dune fmt --auto-promote` on
# staged .ml/.mli/dune files so CI never trips on a missed format pass.
hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled (.githooks/pre-commit)"

# Print the resolved paths so you can debug "where is make looking"
# without having to guess.
paths:
	@echo "REPO_ROOT = $(REPO_ROOT)"
	@echo "BUILD_DIR = $(BUILD_DIR)"
	@echo "CASES_DIR = $(CASES_DIR)"
	@echo "EXTRACT   = $(EXTRACT)"
	@echo "ANALYZE   = $(ANALYZE)"

list:
	@ls -1 $(CASES_DIR) | grep -E '\.ml$$' | sed 's/\.ml$$//'

# Ensure FIXTURE is set and the corresponding .cmt exists on disk.
# Prints the list of available fixtures on a missing-name error so the
# user does not have to `ls` by hand.
_require_fixture:
	@if [ -z "$(FIXTURE)" ]; then \
	  echo "error: FIXTURE=<name> is required" >&2; \
	  echo "" >&2; \
	  echo "available fixtures:" >&2; \
	  ls -1 $(CASES_DIR) | grep -E '\.ml$$' | sed 's/\.ml$$//' | sed 's/^/  /' >&2; \
	  exit 1; \
	fi
	@if [ ! -f "$(CASE_CMT)" ]; then \
	  echo "error: $(CASE_CMT) not found" >&2; \
	  echo "       did you forget to run 'make build' first?" >&2; \
	  exit 1; \
	fi

# `@` prefix suppresses make's command echo, so you see only the
# binaries' output and nothing else. The recipe is still a single
# shell invocation (backslash-continued) so the status capture works.
run: build _require_fixture
	@$(EXTRACT) $(CASE_CMT) | $(ANALYZE); \
	status=$$?; \
	if [ $$status -eq 0 ]; then echo "(exit 0 — clean)"; \
	elif [ $$status -eq 1 ]; then echo "(exit 1 — findings)"; \
	else echo "(exit $$status — error)"; fi; \
	exit $$status

# Same as `run` but passes --warn-only to the analyzer so the exit
# code is always 0 even when findings are present.
warn: build _require_fixture
	@$(EXTRACT) $(CASE_CMT) | $(ANALYZE) --warn-only

ndjson: build _require_fixture
	@$(EXTRACT) --canonical $(CASE_CMT)

debug: build _require_fixture
	@HAMLET_LINT_DEBUG=1 $(EXTRACT) $(CASE_CMT) | $(ANALYZE)

# Internal: promote if PROMOTE=1 was passed on the command line. Silent
# no-op otherwise. Never fails (dune promote exits 0 when nothing to do).
_maybe_promote:
	@if [ "$(PROMOTE)" = "1" ]; then $(DUNE) promote || true; fi
