# Root Makefile: discovers the units in repo.yaml and runs the same-named target in each
# one. No unit's logic lives here; a unit keeps its own Makefile (or package.json script).
# settings-check runs FIRST for check-fast and verify: a red check stops before any unit TARGET is run.
# Unit has target T is make's own verdict by exit status, see README, limits. The inspection asks make -C <unit> -q
# <target>; only if that answers 0 does it ask make -C <unit> -q -B <target> (the same question with every file considered out of date, so the verdict does not depend on whether the
# unit's outputs are fresh, and with every makefile make read named by -o (--assume-old: no makefile is remade and no rule is added to the unit's rule base; GNU make 3.81 remakes an included makefile that has a rule under -B and answers 1 for it, 4.3 does not; the names come from one list pass, asked first: make -C <unit> -q -f <unit makefile> -f <list makefile> <random name>, whose module-owned makefile writes $(MAKEFILE_LIST) into a file in the private temp dir by a parse-time $(shell printf ...), the exit status of the pass is not used, and a list that is empty or names something that is not a file beside the unit leaves the unit unanswerable: fail closed); only if the last
# question asked answered 2 does it ask make -C <unit> -n <target> (exit status only; output discarded). Verdict: -q 1
# = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the
# target sits beside the Makefile and the rule is not .PHONY (the real run says up to date: idle, with a .PHONY hint);
# -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing.
# First question: make parses the unit's Makefile (a parse-time $(shell ...) runs; an included file that has a rule
# may be remade, its recipe IN FULL, plain lines too). Under -q make executes the recipe lines marked + or containing
# $(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper
# bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a +
# line just created may be deleted again). The -B question executes the same classes of lines, passed on to sub-makes
# in question mode as well, but MORE of them, since nothing counts as up to date: the + / $(MAKE) lines of
# prerequisites and sub-make targets that were up to date run too, and no makefile is remade (-o). Under -n make walks the WHOLE recipe, so every + / $(MAKE) line of the target and of
# all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from that remake under the first question, the list pass and -n, no plain recipe line runs under any question; the list pass asks for a name no unit has, so it executes the unit's parse-time $(shell ...), the remake of included makefiles (as the first question does) and the module's one printf that writes the makefile names, nothing else. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape
# measured (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and
# so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a $(MAKE)
# build line is present), except a recipe made only of + / $(MAKE) lines
# that run nothing (verify: with +true, +@echo ok, or $(MAKE) check-fast with check-fast: ;): 3.81 answers 1 to -q
# (present), 4.3 answers 0 to -q and to -q -B (idle, fail-closed: such a recipe verifies nothing); verify: +false
# differs too (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero.
# What runs during the inspection was measured on GNU make 3.81 and 4.3.
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
