.PHONY: check-fast verify
SHELL := /usr/bin/env bash

# check-fast is the cheap gate, the same target name the Go template exposes: install exactly
# what the lock says, then lint, format check, strict typing and the whole test suite
# (Hypothesis in its default "dev" profile).
check-fast:
	uv sync --locked
	uv run ruff check
	uv run ruff format --check
	uv run mypy
	uv run pytest -q

# verify is the presubmit gate: check-fast, then the property tests again in the derandomised
# "ci" Hypothesis profile (a red run is reproducible). Heavier gates -- import-linter,
# pip-audit, coverage thresholds, mutation testing -- are NOT implemented yet; this target
# does not run them and production.yaml does not claim them.
verify: check-fast
	HYPOTHESIS_PROFILE=ci uv run pytest -q
