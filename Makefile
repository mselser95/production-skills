# Makefile — mselser95/production-skills
#
# WHY THIS FILE EXISTS, and it is the finding that produced it.
#
# This repo had no Makefile until 2026-08-29. Every scaffolded repo gets one
# (prod-new/template/Makefile), and its `check-fast` target is where the
# standard says the cheap gate lives -- but the repo that VENDS that Makefile
# had no entrypoint of its own. The consequence was measured, not guessed:
#
#   _shared/probes/row-vacuity-sweep.sh   invoked by CI: 0   by pre-commit: 0
#
# It is wired at prod-new/template/Makefile:28, so every repo scaffolded from
# here runs it. Nothing ran it HERE. Same shape for check-registries.sh, whose
# SELFTEST runs in CI while the check itself never looked at this repo's own
# four registries. Both pass today -- 36 patterns swept, 0 comment-only; 4
# registries present and explicitly empty -- which is precisely why the gap was
# invisible: an unwired gate and a passing gate print the same thing, nothing.
#
# `make check-fast` is the local gate. `make verify` is everything.
#
# THE ORDERING RULE: actionlint runs LOCALLY and first. CI cannot validate its
# own workflow files -- an invalid workflow yields zero checks, not a red one,
# and zero checks is indistinguishable from all checks passing at the branch
# protection layer. It has to be caught before the push that would silence it.

SHELL := /usr/bin/env bash
PROBES := _shared/probes
# RUN-ONCE RUNNER. Every gate and every selftest suite goes through it, so each
# executes once per CI run and leaves one line in .evidence/results.tsv that
# `make evidence` attests to instead of running the gate again (scripts/run-once.sh).
RUN := bash scripts/run-once.sh
.PHONY: help check-fast verify selftests selftests-run lint actionlint gates tcb evidence template-digest mutation mutation-baseline invariants token-report token-baseline skill-weight-baseline eval eval-live db-test

help:
	@echo "check-fast  the cheap local gate (lint + workflow validation + the repo's own probes)"
	@echo "verify      check-fast + every probe selftest + TCB verification"
	@echo "selftests   the probe selftests only"
	@echo "invariants  the ratified invariants in verification/ratified/"
	@echo "evidence    run every gate and write .prod/evidence/<sha>.json (dimension 11)"
	@echo "template-digest  recompute prod-new/TEMPLATE-DIGEST after a reviewed template change"
	@echo "mutation-baseline  re-record benchmarks/mutation-baseline.md after adding/removing cases"
	@echo "token-report    agent token cost per (agentType, model) from ~/.claude* transcripts; exit 1 if tokens/completed rose >25%"
	@echo "token-baseline  re-record benchmarks/token-baseline.md (a trend, not a gate; reads \$$HOME, not in check-fast)"
	@echo "skill-weight-baseline  re-record benchmarks/skill-weight-baseline.md (the file-list and +5 % ratchet of the EAGER and REACHABLE sets; deliberate, never part of a gate run)"
	@echo "eval        skill-eval harness: selftest + corpus lint (hermetic, no agent, not in check-fast)"
	@echo "db-test     Docker, ~1 min: db-postgres bootstrap test, plain then timescale (not in check-fast; CI job db)"
	@echo "eval-live   PAID: every corpus task x claude,codex x skill,bare x N reps; needs EVAL_LIVE=1 (make eval-live EVAL_LIVE=1 N=3)"

# ---- the cheap gate -------------------------------------------------------
# A recipe, not prerequisites, so each of the three runs through the runner under
# the exact command string evidence-record.sh's GATES holds for it. Same order as
# the prerequisites it replaces: actionlint, lint, gates.
check-fast:
	@$(RUN) ci-workflows-valid -- make --no-print-directory actionlint
	@$(RUN) shell-correctness -- make --no-print-directory lint
	@$(MAKE) --no-print-directory gates

# actionlint FIRST and locally -- see the ordering rule above.
actionlint:
	@command -v actionlint >/dev/null || { echo "actionlint missing -- install it: go install github.com/rhysd/actionlint/cmd/actionlint@latest" >&2; exit 2; }
	@actionlint
	@echo "actionlint: workflows valid"

# `make lint` is `scripts/lint-parallel.sh`: shellcheck at -S warning, with -x, over the
# tracked shell scripts, ONE FILE PER shellcheck call, in parallel (LINT_JOBS, default
# min(4, cores)). It remembers nothing between runs.
#
# NO CACHE. An earlier version cached clean verdicts. A sound cache could cover only the
# files that provably source nothing, a small minority of the groups, so a warm run cost
# about as much as a cold one; it was also the part that failed review twice.
#
# WHAT IS LINTED: REAL FILES. Every tracked *.sh is resolved to its real path (symlinks
# followed) and each distinct real file is linted exactly once, `shellcheck -x -S warning
# -- <path>` from the repo root. A tracked symlink is not a script of its own, it IS its
# target; findings print under the real path plus `also reachable as: <links>`. A link
# out of the tree, dangling or to a directory is exit 2. No verdict is shared between
# different real files, even byte-identical ones: four review rounds failed on predicting
# what shellcheck follows (rc files, source-path, ignored or binary sources, links out of
# the tree), and shellcheck applies those itself. Measured here: 176 tracked paths, 25 of
# them symlinks, 151 real files; sharing between byte-identical real files would have saved
# 22 invocations (761 KB), including the second copy of the largest script
# (verify-standard.sh, about 3 s of CPU), so those are linted separately on purpose.
# A symlinked script that sources directory-relatively (source-path=SCRIPTDIR) is checked
# only against its real directory's siblings.
#
# -x per file is LOOSER than the old single-call recipe in two cases: a script sourcing a
# tracked non-.sh file or an untracked file is followed and can be clean where the old
# recipe printed a false positive. So an untracked or out-of-tree sourced file can make the
# local verdict differ from CI's, which has only the clone.
#
# COST. 151 shellcheck invocations; the largest real file (verify-standard.sh, about 3 s of
# CPU alone) is the floor. CPU of one run, measured 2026-11-27 on a laptop (macOS, 4 jobs,
# shellcheck 0.11.0, load average about 9 from other work): about 19 s (17 user + 2
# system); a run under load average 50+ cost about 34 s. No wall-clock promise: it depends on load.
#
# TRACKED FILES ONLY (`git ls-files`). The gate used to walk the working tree
# while CI lints what the clone contains, so the two ran over different sets:
# raising the severity turned the local gate red on gitignored per-user
# `config.sh` files that CI has never seen, and a gate that fails only on the
# author's machine is one they learn to bypass. `git ls-files` also covers a NEW
# file the moment it is staged, which is when the pre-commit hook runs, so nothing
# being committed escapes it; uncommitted scratch and per-user config are skipped.
#
# ONE FILE PER CALL, WITH -x. Without -x shellcheck follows a sourced file only if
# that file happens to be on the same command line, so a verdict depended on which
# files shared a call. Every file is now linted alone and sources are always followed.
#
# Exit codes (0 clean, 1 findings, 2 tool error with 2 over 1; the list of what is a
# tool error, timeouts and refused links included, is in the header of the script). A lint that cannot run must not look like one that found
# nothing. The recipe is ONE command on purpose: make grades its exit status directly
# (the old multi-line recipe once stayed green over a real finding because only its
# trailing `echo` was graded).
lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; }
	@bash scripts/lint-parallel.sh

# The repo's own probes, run against the repo itself -- the half that was missing.
gates:
	@$(RUN) skills-structural -- bash $(PROBES)/skills-static.sh
	@$(RUN) agents-token-budget -- bash $(PROBES)/agents-budget.sh
	@$(RUN) skill-weight -- bash $(PROBES)/skill-weight.sh
	@$(RUN) policy-coverage -- bash $(PROBES)/policy-coverage.sh
	@$(RUN) row-vacuity -- bash $(PROBES)/row-vacuity-sweep.sh
	@$(RUN) row-catalogue -- bash $(PROBES)/row-catalogue.sh
	@$(RUN) liability-registries -- bash $(PROBES)/check-registries.sh
# The shell files this repo VENDORS into scaffolds are held to the template's own
# gate-hygiene rules HERE, before a consumer's check-fast finds them: the
# single-suite selftest shipped a PREFIX-ASSIGN-EXPAND that only the consumer's
# gate-hygiene-fitness.sh caught, because nothing in this repo ran it over the
# files it vendors. Findings fail; the latent GREPQ advisories are printed.
	@$(RUN) gate-hygiene -- bash prod-new/template/scripts/gate-hygiene-fitness.sh _shared/probes prod-new/template/scripts prod-new/modules/*/scripts
# And the wiring of that step itself: probe-wiring over the template's scripts
# reports gate-hygiene-fitness.sh as an orphan the moment the line above is
# deleted. Every other template script is a declared exception (run downstream).
	@$(RUN) gates-are-driven-template -- bash $(PROBES)/probe-wiring.sh prod-new/template/scripts
	@$(RUN) gates-are-driven -- bash $(PROBES)/probe-wiring.sh
# scripts/ too, added after review noticed nothing covered it: evidence-record.sh
# and instantiate-template.sh are gates by any reasonable reading, and they lived
# outside the only check that asks whether a gate is driven.
	@$(RUN) gates-are-driven-scripts -- bash $(PROBES)/probe-wiring.sh scripts
# The modules' scripts (prod-new/modules/*/scripts), one probe-wiring run per module
# because the tool takes ONE directory: db-pin-check.sh was an orphan gate until this
# loop existed. Zero module dirs is an error, not a pass. db-pin-verify-live.sh needs
# Docker and is a declared exception in probe-wiring.sh. ONE recorded gate: the loop
# is the command string (--as, because the argv is `bash -c <loop>`), byte-equal to
# the GATES entry of the same id in scripts/evidence-record.sh.
	@$(RUN) --as 'rc=0; n=0; for d in prod-new/modules/*/scripts; do [ -d "$$d" ] || continue; bash $(PROBES)/probe-wiring.sh "$$d" || rc=1; n=$$((n+1)); done; [ "$$n" -gt 0 ] && [ "$$rc" = 0 ]' gates-are-driven-modules -- bash -c 'rc=0; n=0; for d in prod-new/modules/*/scripts; do [ -d "$$d" ] || continue; bash $(PROBES)/probe-wiring.sh "$$d" || rc=1; n=$$((n+1)); done; [ "$$n" -gt 0 ] && [ "$$rc" = 0 ]'
# The database image pin: the lock is read offline (no network, no Docker). A broken
# lock, or a broken gate (its selftest runs in `make selftests`), goes red here; the
# module's compose files are checked against the lock in the same invocation.
	@$(RUN) db-image-pin -- bash prod-new/modules/db-postgres/scripts/db-pin-check.sh prod-new/modules/db-postgres/db/image.lock --compose prod-new/modules/db-postgres/db/compose.yml prod-new/modules/db-postgres/db/compose.timescale.yml
# probe-wiring counts a Makefile target as an invoker even when nothing calls the
# target, so it cannot see that `db-test` (the only runner of db-bootstrap-test.sh)
# is driven by no workflow. This is that missing half, for this one target.
	@$(RUN) db-test-ci-wired -- bash prod-new/modules/db-postgres/scripts/db-ci-wired.sh .github/workflows/pr.yaml
# And the ratified invariants: an invariant nothing runs is precisely the shape
# the three of them exist to refuse.
	@$(RUN) gates-are-driven-ratified -- bash $(PROBES)/probe-wiring.sh verification/ratified
# The vended template's VERSION, and the producer side of the drift question.
# check-template-drift.sh runs in the SCAFFOLDED repo and answers "am I behind?";
# this runs here, where the template actually moves, and refuses to let the vended
# surface change without the digest being updated in the same commit. Downstream
# repos pin that digest, so a silent change is a silent divergence in every one.
	@$(RUN) template-version -- bash scripts/template-digest.sh
# The gap report is the document this whole bootstrap produces, and its summary
# is what gets read. It said high(0) while two high rows sat in a second table
# nobody had updated, and one of them hid a genuinely open item. The numbers are
# derived from the tables now and compared to what the prose claims.
	@$(RUN) gap-report-consistent -- bash scripts/gap-report-consistency.sh
# Nothing in this repo executed the template's workflows -- not actionlint, not the
# scaffold job's check-fast -- so an installer piped from a mutable branch shipped
# to every scaffold unnoticed. This reads them: remote scripts must be pinned to a
# commit (or checksummed) and tools must not install at @latest/@main.
	@$(RUN) template-workflow-pins -- bash scripts/template-workflow-pins.sh

# The database module's bootstrap test: starts a REAL PostgreSQL per variant (Docker,
# ~30 s each), so it is in no aggregate target. The pr.yaml job `db` runs it.
# Sequential, first failure stops the target (make aborts on a non-zero recipe line).
db-test:
	@bash prod-new/modules/db-postgres/scripts/db-bootstrap-test.sh --variant plain
	@bash prod-new/modules/db-postgres/scripts/db-bootstrap-test.sh --variant timescale

# ---- the full gate --------------------------------------------------------
verify: check-fast selftests invariants tcb mutation

# THE RATIFIED INVARIANTS. Each is an executable test whose failure IS the
# detection -- ratification here is not a status field, and the standard says so
# in as many words: writing the key without the test 'launders scaffold-time
# authorship into ratification, which is the one thing the human gate exists to
# prevent'. Each has a package in .prod/ratify-queue/ carrying the mutation that
# was RUN to prove the test is not decoration.
#
# Globbed with a zero-guard, for the same reason selftests are: a list is a
# denominator somebody has to remember, and an invariant nothing runs is exactly
# the shape these three exist to refuse.
invariants:
	@set -e; n=0; \
	  for t in verification/ratified/inv-*.sh; do \
	    [ -f "$$t" ] || continue; \
	    printf '  %-52s ' "$$(basename $$t)"; \
	    if bash "$$t" >/dev/null 2>&1; then echo ok; else echo FAIL; bash "$$t" 2>&1 | tail -20; exit 1; fi; \
	    n=$$((n+1)); \
	  done; \
	  if [ "$$n" -eq 0 ]; then echo 'invariants: found ZERO ratified invariants -- refusing to report a pass over an empty set' >&2; exit 2; fi; \
	  echo "invariants: $$n ratified invariant(s) hold"

# In `verify`, NOT in `check-fast`. It re-runs all ten selftests to count what
# they actually execute, which costs about as much as the selftests target
# itself -- putting it in the pre-commit path would take the hook from ~10s to
# ~22s, and a hook people wait for is a hook people bypass with --no-verify.
# A trend belongs in the fuller gate anyway.
mutation:
	@bash scripts/mutation-baseline.sh

# Every selftest, enumerated by GLOB rather than by a list -- which directly
# contradicts .github/workflows/pr.yaml:48 ("Listed individually, never
# globbed"), so the disagreement is settled here rather than left for a reader
# to notice.
#
# The workflow's objection is exactly right about a BARE glob: `for f in
# _shared/probes/*-selftest.sh` reports success over an empty match if the
# directory is ever renamed, which is the fail-open shape these files exist to
# refuse. That is why the counter below exists and why it exits 2 on zero. A
# glob with a zero-guard is not fail-open; it fails on the same input that
# would make a list fail, and it cannot silently omit the one added last.
#
# Both denominators have a failure mode and they are opposite ones: a list
# shrinks silently when someone forgets to extend it, a glob widens silently
# when something unrelated matches the pattern. The list's failure is the one
# this repo has actually suffered -- sbom-ordering and check-registries sat RED
# for weeks because nothing invoked them -- so the glob is the safer default
# HERE, with the guard closing the hole the workflow names.
# Template selftests, by origin (checked with cmp against _shared/probes and _shared/probes/tests):
#   byte-identical MIRRORS of a _shared source, which the glob above already runs:
#     acceptance-audit, acceptance-coverage, acceptance-gap, check-registries, coverage-ratchet,
#     gate-run, load-rows, non-vacuity, observability-provenance, probe-self-gate,
#     sbom-ordering, single-suite-run
#   TEMPLATE-ONLY, no _shared source (the glob cannot see them):
#     changed-line-coverage, check-template-drift, probe-selftests-skip   -- run here, listed below
#     error-handling-fitness, kill-durability-state, retry   -- NOT run by this target; they run
#                                                               only in a generated repo
# The listed ones run from the framework tree so they are not first run downstream.
TEMPLATE_SELFTESTS = prod-new/template/scripts/tests/changed-line-coverage-selftest.sh prod-new/template/scripts/tests/check-template-drift-selftest.sh prod-new/template/scripts/tests/probe-selftests-skip-selftest.sh
# The suites the workflow used to run one by one, by hand. That hand list had a
# reason (a glob over a renamed directory reports success over nothing), and the
# glob's own zero-guard only catches the case where EVERY directory vanished. This
# list is the other half: each of these must exist AND be among the suites that ran,
# or the target exits 2 -- so deleting, renaming or un-globbing one is loud, and the
# workflow no longer needs a second, repeated execution to notice.
REQUIRED_SELFTESTS = $(PROBES)/skills-static-selftest.sh $(PROBES)/load-rows-selftest.sh $(PROBES)/tests/probe-self-gate-selftest.sh $(PROBES)/check-registries-selftest.sh $(PROBES)/non-vacuity-selftest.sh $(PROBES)/sbom-ordering-selftest.sh $(PROBES)/agents-budget-selftest.sh $(PROBES)/skill-weight-selftest.sh $(PROBES)/prove-mutation-selftest.sh $(PROBES)/acceptance-coverage-selftest.sh
# The entry point records the WHOLE run under the command string `make evidence`
# attests to; selftests-run does the work and records each suite (with its own case
# count, which mutation-baseline.sh reads instead of running the suite again).
selftests:
	@$(RUN) --as 'make --no-print-directory selftests' probe-selftests -- $(MAKE) --no-print-directory selftests-run
selftests-run:
	@set -e; n=0; ran=" "; \
	  for ts in $(TEMPLATE_SELFTESTS); do [ -f "$$ts" ] || { echo "selftests: $$ts is missing: a vendored selftest nothing runs here is first exercised in someone else's CI" >&2; exit 2; }; done; \
	  for rs in $(REQUIRED_SELFTESTS); do [ -f "$$rs" ] || { echo "selftests: $$rs is missing: it was run by name in CI and must stay" >&2; exit 2; }; done; \
	  for t in $(PROBES)/*-selftest.sh $(PROBES)/tests/*-selftest.sh scripts/tests/*-selftest.sh prod-new/modules/*/scripts/tests/*-selftest.sh $(TEMPLATE_SELFTESTS); do \
	    [ -f "$$t" ] || continue; \
	    printf '  %-52s ' "$$(basename $$t)"; \
	    if tl=$$($(RUN) --quiet --count "selftest:$$t" -- bash "$$t"); then echo "ok"; else echo "FAIL"; printf '%s\n' "$$tl"; exit 1; fi; \
	    n=$$((n+1)); ran="$$ran$$t "; \
	  done; \
	  for rs in $(REQUIRED_SELFTESTS); do case "$$ran" in *" $$rs "*) ;; *) echo "selftests: $$rs exists but the glob did not run it" >&2; exit 2;; esac; done; \
	  if [ "$$n" -eq 0 ]; then echo "selftests: found ZERO selftests -- refusing to report a pass over an empty set" >&2; exit 2; fi; \
	  echo "selftests: $$n passed"

# TCB verification is part of `verify` because the probes above are only
# meaningful if the installed copy is the one they describe.
tcb:
	@bash install.sh --verify

# EVIDENCE RECORD (dimension 11, reproducibility). Separate from `verify` on
# purpose: verify answers "is this tree green right now" and prints to a terminal
# that scrolls away, while this writes the durable answer to "under what standard
# was this commit held?". Ninety days later the CI log is gone and only the
# record can answer it.
#
# Not folded into `verify` because a record written on every local run of a
# dirty tree is noise -- those land as dirty-*.json and are gitignored, which is
# also why the filename discipline matters: a <sha>.json name is an ATTESTATION
# and must never be produced from an unclean tree.
#
# --attest: a gate that already ran in this job through scripts/run-once.sh, on the
# same command string and the same tree, is ATTESTED from its recorded line instead
# of being executed again; anything else is executed here. See evidence-record.sh.
evidence:
	@bash scripts/evidence-record.sh --attest

# Regenerating is a deliberate act, never part of a gate run. A digest recomputed
# automatically would certify whatever happened to be on disk -- which is exactly
# the "re-stamp to silence the report" failure the provenance file warns about.
template-digest:
	@bash scripts/template-digest.sh --write

# Re-recording is deliberate, like the template digest: a baseline refreshed
# automatically records whatever the suite happens to do today, which is how a
# shrinking one stops being visible.
mutation-baseline:
	@bash scripts/mutation-baseline.sh --write

# Agent token cost, as a TREND. Deliberately outside `gates`/`check-fast`: it
# reads the user's home directory (transcripts), not the repo.
token-report:
	@bash scripts/token-report.sh

token-baseline:
	@bash scripts/token-report.sh --write

# Deliberate re-recording of the skill eager-weight ratchet, like the other baselines.
skill-weight-baseline:
	@bash $(PROBES)/skill-weight.sh --write

# ---- skill-eval harness (benchmarks/eval/README.md) --------------------------
# eval: hermetic. The corpus may not exist yet; only then is an empty lint allowed.
eval:
	@bash benchmarks/eval/selftest.sh
	@bash benchmarks/eval/lib/libtests.sh
	@if [ -d benchmarks/eval/corpus ]; then bash benchmarks/eval/lint.sh; else bash benchmarks/eval/lint.sh --allow-empty; fi

# eval-live: spends money (real agent runs). Refuses unless EVAL_LIVE=1; prints the plan either way.
N ?= 3
eval-live:
	@N=$(N) bash benchmarks/eval/lib/live.sh
