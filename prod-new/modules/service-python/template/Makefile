# Gate entry points. The lanes and tools (lint, typecheck, test-*, lock-check, audit, fmt) are in
# unit.mk; a monorepo root delegates with `$(MAKE) -C <unit> <target>`.
SHELL := /usr/bin/env bash
# Every `uv` call below honours the lock and fails when it is stale (never a re-resolve).
export UV_LOCKED := 1

.PHONY: check-fast verify
.DEFAULT_GOAL := check-fast

include unit.mk

# check-fast is the cheap gate (about 10 s), the same target name the Go template exposes:
# install exactly what the lock says, then lint, format check, strict typing and the whole
# test suite (Hypothesis in its default "dev" profile).
check-fast:
	uv sync --locked
	uv run ruff check
	uv run ruff format --check
	uv run mypy
	uv run pytest -q
	@echo "check-fast: ok (lock, ruff, format, mypy --strict, pytest)"

# verify is the presubmit gate: check-fast, lock consistency, the dependency audit (network;
# fails closed), then the property tests again in the derandomised "ci" Hypothesis profile (a
# red run is reproducible). Coverage, import-linter and mutation testing are NOT implemented;
# README "Gates" lists what is and is not gated.
verify: check-fast lock-check audit
	HYPOTHESIS_PROFILE=ci uv run pytest -q
	@echo "verify: ok (check-fast, lock-check, audit, pytest ci profile)"
