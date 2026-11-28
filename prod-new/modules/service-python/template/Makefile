# Gate entry points. The lanes and tools (lint, typecheck, test-*, lock-check, audit, fmt) are in
# unit.mk; a monorepo root delegates with `$(MAKE) -C <unit> <target>`.
SHELL := /usr/bin/env bash
# Every `uv` call below honours the lock and fails when it is stale (never a re-resolve).
export UV_LOCKED := 1
# The directory of THIS Makefile, so `make -f <unit>/Makefile <target>` from anywhere includes
# unit.mk and runs every `uv` call inside the unit: IN is the prefix of each such recipe line.
# A trailing slash is part of UNIT_DIR.
UNIT_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
IN := cd "$(UNIT_DIR)" &&

.PHONY: check-fast verify
.DEFAULT_GOAL := check-fast

include $(dir $(lastword $(MAKEFILE_LIST)))unit.mk

# check-fast is the cheap gate (about 10 s), the same target name the Go template exposes:
# install exactly what the lock says, then lint, format check, strict typing and the whole
# test suite (Hypothesis in its default "dev" profile).
check-fast:
	$(IN) uv sync --locked
	$(IN) uv run ruff check
	$(IN) uv run ruff format --check
	$(IN) uv run mypy
	$(IN) uv run pytest -q
	@echo "check-fast: ok (lock, ruff, format, mypy --strict, pytest)"

# verify is the presubmit gate: check-fast, lock consistency, the lanes covering every test, the
# dependency audit (network; fails closed), then the property tests again in the derandomised
# "ci" Hypothesis profile (a red run is reproducible). Coverage, import-linter and mutation
# testing are NOT implemented; README "Gates" lists what is and is not gated.
verify: check-fast lock-check test-lanes-cover audit
	$(IN) HYPOTHESIS_PROFILE=ci uv run pytest -q
	@echo "verify: ok (check-fast, lock-check, lanes cover every test, audit, pytest ci profile)"
