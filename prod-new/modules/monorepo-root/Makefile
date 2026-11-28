# Root Makefile: discovers the units in repo.yaml and runs the same-named target in each
# one. No unit's logic lives here; a unit keeps its own Makefile (or package.json script).
# settings-check runs FIRST for check-fast and verify: a red check stops before any unit TARGET is run
# (it reads each unit's rule data base with one `make -pq -- .`, which parses the unit's Makefile
# and runs no recipe line; see README, limits).
SHELL := /bin/bash
.PHONY: check-fast verify test settings-check

check-fast verify: settings-check
	@bash scripts/monorepo-run.sh $@

test:
	@bash scripts/monorepo-run.sh $@

settings-check:
	@bash scripts/monorepo-settings-check.sh
