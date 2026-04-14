# hamlet-lint dev Makefile — shortcuts for running the linter on
# individual fixtures, inspecting raw ND-JSON, and iterating on the
# walker without having to remember long paths.
#
# Usage:
#   make <target> [FIXTURE=<name>]
#
# Examples:
#   make run     FIXTURE=wrapper_stale
#   make ndjson  FIXTURE=wrapper_stale
#   make debug   FIXTURE=wrapper_stale
#   make test

FIXTURE    ?=

# Anchor every path to the directory containing THIS Makefile, so that
# the targets still work when make is invoked from a subdirectory.
REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  := $(REPO_ROOT)/_build/default
CASES_DIR  := $(REPO_ROOT)/test/cases
EXTRACT    := $(BUILD_DIR)/extract/main.exe
ANALYZE    := $(BUILD_DIR)/analyzer/main.exe

# Dune wraps each fixture library as `hamlet_lint_fixture_<name>` and
# the inner module as `<Name_capitalised>`, producing a mangled cmt
# under .objs/byte/. Capitalise the first letter of $(FIXTURE) at
# target-evaluation time so `run FIXTURE=wrapper_stale` finds
# `Wrapper_stale.cmt` without the caller having to know. Portable
# cut+tr rather than sed '\U' (GNU-only, breaks on BSD sed / macOS).
FIXTURE_HEAD = $(shell echo "$(FIXTURE)" | cut -c1 | tr '[:lower:]' '[:upper:]')
FIXTURE_TAIL = $(shell echo "$(FIXTURE)" | cut -c2-)
FIXTURE_CAP  = $(FIXTURE_HEAD)$(FIXTURE_TAIL)
CASE_CMT     = $(BUILD_DIR)/test/cases/$(FIXTURE)/.hamlet_lint_fixture_$(FIXTURE).objs/byte/hamlet_lint_fixture_$(FIXTURE)__$(FIXTURE_CAP).cmt

.PHONY: help build test run warn ndjson debug all list paths _require_fixture

.DEFAULT_GOAL := help

help:
	@echo "hamlet-lint dev targets"
	@echo ""
	@echo "  build                          Build the linter binaries"
	@echo "  test                           Run the linter's alcotest + e2e suite"
	@echo "  all                            build + test + fmt + doc + opam lint"
	@echo "  list                           List available fixture names under test/cases/"
	@echo ""
	@echo "  run     FIXTURE=<name>         Run linter on a single fixture, pretty report (exit 1 on findings)"
	@echo "  warn    FIXTURE=<name>         Same as run but always exits 0 (analyzer --warn-only)"
	@echo "  ndjson  FIXTURE=<name>         Show the canonical ND-JSON the extractor emits"
	@echo "  debug   FIXTURE=<name>         Run with HAMLET_LINT_DEBUG=1 to see walker skips"

build:
	opam exec -- dune build

test: build
	opam exec -- dune runtest

all: build test
	opam exec -- dune build @fmt @doc
	opam lint hamlet-lint.opam

# Print the resolved paths so you can debug "where is make looking"
# without having to guess.
paths:
	@echo "REPO_ROOT = $(REPO_ROOT)"
	@echo "BUILD_DIR = $(BUILD_DIR)"
	@echo "CASES_DIR = $(CASES_DIR)"
	@echo "EXTRACT   = $(EXTRACT)"
	@echo "ANALYZE   = $(ANALYZE)"

list:
	@ls -1 $(CASES_DIR) | grep -vE '^(README\.md|dune)$$'

# Ensure FIXTURE is set and the corresponding .cmt exists on disk.
# Prints the list of available fixtures on a missing-name error so the
# user does not have to `ls` by hand.
_require_fixture:
	@if [ -z "$(FIXTURE)" ]; then \
	  echo "error: FIXTURE=<name> is required" >&2; \
	  echo "" >&2; \
	  echo "available fixtures:" >&2; \
	  ls -1 $(CASES_DIR) | grep -vE '^(README\.md|dune)$$' | sed 's/^/  /' >&2; \
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
