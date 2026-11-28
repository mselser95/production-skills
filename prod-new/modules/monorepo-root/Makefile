# Root Makefile: discovers the units in repo.yaml and runs the same-named target in each
# one. No unit's logic lives here; a unit keeps its own Makefile (or package.json script).
# settings-check runs FIRST for check-fast and verify: a red check stops before any unit TARGET is run.
# "Unit has target T" is `make -C <unit> -q <T>` per unit and target and, only when that answers 2, `make -C <unit> -n
# <T>` (exit status only; the second question decides: 0 = present, 2 = missing); see README, limits: make parses the
# unit's Makefile (a parse-time $(shell ...) runs; an included file that has a rule may be remade, its recipe IN FULL,
# plain lines too). Under -q make executes the recipe lines marked `+` or containing $(MAKE) of the target and of its
# prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-
# of-date prerequisite whose recipe starts with a plain line; a file target that a `+` line just created may be
# deleted again). Under -n (asked only after a -q answer of 2) make walks the WHOLE recipe, so every `+` / $(MAKE)
# line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its `+` lines and
# not its plain lines). Apart from that remake, no plain recipe line runs under either question.
# GNU make 4 answers 1 where 3.81 answers 2 to `-q` for a recipe that starts with a `$(MAKE)` or `+` line, and the judgment is the same (`verify: $(MAKE) check-fast` is present on both); `verify: +false` differs (3.81: `-q` 2 and `-n` 2 = missing; 4.3: `-q` 1 = present) and on both the root `make verify` ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3.
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
