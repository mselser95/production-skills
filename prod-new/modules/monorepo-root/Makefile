# Root Makefile: discovers the units in repo.yaml and runs the same-named target in each
# one. No unit's logic lives here; a unit keeps its own Makefile (or package.json script).
# settings-check runs FIRST for check-fast and verify: a red check stops before any unit TARGET is run.
# "Unit has target T" is `make -C <unit> -q <T>` per unit and target (exit status only); see README, limits:
# make parses the unit's Makefile (a parse-time $(shell ...) runs, an included file that has a rule may be remade) and,
# as GNU make does in question mode, executes the recipe lines marked `+` or containing $(MAKE) of the target and of its
# prerequisites, each recipe at most up to its first line that is neither; no other recipe line runs (measured on GNU make 3.81).
SHELL := /bin/bash
.PHONY: check-fast verify test settings-check lock lock-check

check-fast verify: settings-check
	@bash scripts/monorepo-run.sh $@

test:
	@bash scripts/monorepo-run.sh $@

settings-check:
	@bash scripts/monorepo-settings-check.sh

# The lockfile is GENERATED, never shipped (it names the repository's own package scope): `make lock`
# writes/updates the root pnpm-lock.yaml (needs the registry); `make lock-check` fails when the
# lockfile is missing or does not match the workspace manifests, and runs OFFLINE (no store, no
# registry needed). lock-check is not a prerequisite of `verify`: a fresh scaffold has no lockfile
# until `make lock`, and a repository of Go/Rust/Python units may have no pnpm on its CI image.
lock:
	@pnpm install --lockfile-only --ignore-scripts

lock-check:
	@pnpm install --frozen-lockfile --lockfile-only --ignore-scripts --offline
