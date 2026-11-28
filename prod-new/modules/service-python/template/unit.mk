# unit.mk -- this unit's lane and tool targets (lint, fmt, typecheck, test, test-unit,
# test-contract, test-architecture, architecture, test-lanes-cover, lock-check, audit). The two
# entry points production.yaml names, `check-fast` and `verify`, are in the Makefile that
# includes this file (a scaffold test reads them there). A monorepo root delegates with
# `$(MAKE) -C <unit> <target>`; the names match the Go template (check-fast, verify, test, and
# `architecture`, the alias below) so the root never needs the language.
#
# Every recipe runs from a clean checkout with only `uv` installed, against the LOCKED set:
# the Makefile exports UV_LOCKED=1, so a stale lock is an error for every `uv` call here,
# never a re-resolve, and defines IN (cd to the unit's directory first). make stops at the
# first failing line, and each target prints ONE final line `<target>: ok`, which a failing
# target therefore never prints. No recipe line starts with `-` or ends in `|| true`.
.PHONY: lint fmt typecheck test test-unit test-contract test-architecture architecture \
        test-lanes-cover lock-check audit
.NOTPARALLEL:

lint:
	$(IN) uv run ruff check
	$(IN) uv run ruff format --check
	@echo "lint: ok"

fmt:
	$(IN) uv run ruff format
	$(IN) uv run ruff check --fix

# The one type checker is mypy in strict mode (see README, "Gates").
typecheck:
	$(IN) uv run mypy
	@echo "typecheck: ok (mypy --strict)"

# Lanes are directories under tests/ (`test` is all of them); `test-lanes-cover` proves that.
LANES := tests/unit tests/contract tests/architecture

test:
	$(IN) uv run pytest -q
	@echo "test: ok"

test-unit:
	$(IN) uv run pytest -q tests/unit
	@echo "test-unit: ok"

test-contract:
	$(IN) uv run pytest -q tests/contract
	@echo "test-contract: ok"

# Zone direction and the stdlib allowlist of the domain: tests/architecture/test_boundaries.py.
test-architecture:
	$(IN) uv run pytest -q tests/architecture
	@echo "test-architecture: ok"

# The Go template names this lane `architecture`: an alias, so a monorepo root can delegate
# `$(MAKE) -C <unit> architecture` for either language.
architecture: test-architecture

# The test node ids `make test` collects equal the union of the lanes' (collection only, no test
# runs): a test file outside every lane would fail `make test` yet pass every lane target. An
# empty collection is a failure too.
test-lanes-cover:
	@all="$$($(IN) uv run pytest --collect-only -q 2>/dev/null | grep '::' | sort -u)" \
	  && lanes="$$(for l in $(LANES); do $(IN) uv run pytest --collect-only -q $$l 2>/dev/null; done | grep '::' | sort -u)" \
	  && test -n "$$all" \
	  && orphans="$$(comm -23 <(printf '%s\n' "$$all") <(printf '%s\n' "$$lanes"))" \
	  && { test -z "$$orphans" || { printf 'test-lanes-cover: FAIL tests outside every lane:\n%s\n' "$$orphans" >&2; false; }; }
	@echo "test-lanes-cover: ok"

# `uv lock --check`: the lock must equal what pyproject.toml asks for (no write, no sync).
lock-check:
	$(IN) uv lock --check
	@echo "lock-check: ok"

# Advisory audit of the locked set. Needs the network, so it is part of `verify` and CI only;
# it FAILS CLOSED when the advisory service cannot be reached. The only way past a finding is
# a dated entry in gates/audit-waivers.txt (an expired entry is itself a failure).
audit:
	$(IN) uv run python gates/audit.py
