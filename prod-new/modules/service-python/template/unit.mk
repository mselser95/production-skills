# unit.mk -- this unit's lane and tool targets (lint, fmt, typecheck, test, test-unit,
# test-contract, test-architecture, lock-check, audit). The two entry points production.yaml
# names, `check-fast` and `verify`, are in the Makefile that includes this file (a scaffold test
# reads them there). A monorepo root delegates with `$(MAKE) -C <unit> <target>`; the names
# match the Go template (check-fast, verify, test) so the root never needs the language.
#
# Every recipe runs from a clean checkout with only `uv` installed, against the LOCKED set:
# the Makefile exports UV_LOCKED=1, so a stale lock is an error for every `uv` call here,
# never a re-resolve. make stops at the first failing line, and each target prints ONE final
# line `<target>: ok`, which a failing target therefore never prints.
.PHONY: lint fmt typecheck test test-unit test-contract test-architecture \
        lock-check audit
.NOTPARALLEL:

lint:
	uv run ruff check
	uv run ruff format --check
	@echo "lint: ok"

fmt:
	uv run ruff format
	uv run ruff check --fix

# The one type checker is mypy in strict mode (see README, "Gates").
typecheck:
	uv run mypy
	@echo "typecheck: ok (mypy --strict)"

# Lanes are directories under tests/ (`test` is all of them).
test:
	uv run pytest -q
	@echo "test: ok"

test-unit:
	uv run pytest -q tests/unit
	@echo "test-unit: ok"

test-contract:
	uv run pytest -q tests/contract
	@echo "test-contract: ok"

# Zone direction and the stdlib allowlist of the domain: tests/architecture/test_boundaries.py.
test-architecture:
	uv run pytest -q tests/architecture
	@echo "test-architecture: ok"

# `uv lock --check`: the lock must equal what pyproject.toml asks for (no write, no sync).
lock-check:
	uv lock --check
	@echo "lock-check: ok"

# Advisory audit of the locked set. Needs the network, so it is part of `verify` and CI only;
# it FAILS CLOSED when the advisory service cannot be reached. The only way past a finding is
# a dated entry in gates/audit-waivers.txt (an expired entry is itself a failure).
audit:
	uv run python gates/audit.py
