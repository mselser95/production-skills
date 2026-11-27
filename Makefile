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
.PHONY: help check-fast verify selftests lint actionlint gates tcb evidence template-digest mutation mutation-baseline invariants token-report token-baseline eval eval-live

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
	@echo "eval        skill-eval harness: selftest + corpus lint (hermetic, no agent, not in check-fast)"
	@echo "eval-live   PAID: every corpus task x claude,codex x skill,bare x N reps; needs EVAL_LIVE=1 (make eval-live EVAL_LIVE=1 N=3)"

# ---- the cheap gate -------------------------------------------------------
check-fast: actionlint lint gates

# actionlint FIRST and locally -- see the ordering rule above.
actionlint:
	@command -v actionlint >/dev/null || { echo "actionlint missing -- install it: go install github.com/rhysd/actionlint/cmd/actionlint@latest" >&2; exit 2; }
	@actionlint
	@echo "actionlint: workflows valid"

# `make lint` is `scripts/lint-parallel.sh`: shellcheck at -S warning, with -x, over the
# tracked shell scripts, ONE FILE PER shellcheck call, in parallel (LINT_JOBS, default
# min(4, cores)). It remembers nothing between runs.
#
# NO CACHE. An earlier version cached clean verdicts. With a sound rule, 118 of the 129
# distinct groups could not be cached, so the cache saved 11 files and a warm run cost as
# much as a cold one; it was also the part that failed review twice.
#
# DEDUPLICATION. install.sh mirrors the shared probes into the skills and the template, so
# `verify-standard.sh` appears eleven times byte-identically. Within one run, two paths
# share ONE shellcheck run when their content and rc chain are equal. Premise, measured
# and kept as a selftest case: with -x from the repo root a relative source resolves
# against the working directory, so identical copies get the same verdict. A path whose
# bytes, rc files or $SHELLCHECK_OPTS contain SCRIPTDIR is never shared.
#
# COST, measured on a loaded laptop (shellcheck 0.11.0): 176 tracked files, 129 runs of
# shellcheck on every invocation, about 8.5 to 9.2 s. verify-standard.sh, about 5 s, is
# the floor.
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
# Exit 0 clean, 1 findings, 2 tool error (shellcheck missing, zero files, exit >= 2,
# killed), with 2 over 1. A lint that cannot run must not look like one that found
# nothing. The recipe is ONE command on purpose: make grades its exit status directly
# (the old multi-line recipe once stayed green over a real finding because only its
# trailing `echo` was graded).
lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; }
	@bash scripts/lint-parallel.sh

# The repo's own probes, run against the repo itself -- the half that was missing.
gates:
	@bash $(PROBES)/skills-static.sh
	@bash $(PROBES)/agents-budget.sh
	@bash $(PROBES)/policy-coverage.sh
	@bash $(PROBES)/row-vacuity-sweep.sh
	@bash $(PROBES)/check-registries.sh
# The shell files this repo VENDORS into scaffolds are held to the template's own
# gate-hygiene rules HERE, before a consumer's check-fast finds them: the
# single-suite selftest shipped a PREFIX-ASSIGN-EXPAND that only the consumer's
# gate-hygiene-fitness.sh caught, because nothing in this repo ran it over the
# files it vendors. Findings fail; the latent GREPQ advisories are printed.
	@bash prod-new/template/scripts/gate-hygiene-fitness.sh _shared/probes prod-new/template/scripts
# And the wiring of that step itself: probe-wiring over the template's scripts
# reports gate-hygiene-fitness.sh as an orphan the moment the line above is
# deleted. Every other template script is a declared exception (run downstream).
	@bash $(PROBES)/probe-wiring.sh prod-new/template/scripts
	@bash $(PROBES)/probe-wiring.sh
# scripts/ too, added after review noticed nothing covered it: evidence-record.sh
# and instantiate-template.sh are gates by any reasonable reading, and they lived
# outside the only check that asks whether a gate is driven.
	@bash $(PROBES)/probe-wiring.sh scripts
# And the ratified invariants: an invariant nothing runs is precisely the shape
# the three of them exist to refuse.
	@bash $(PROBES)/probe-wiring.sh verification/ratified
# The vended template's VERSION, and the producer side of the drift question.
# check-template-drift.sh runs in the SCAFFOLDED repo and answers "am I behind?";
# this runs here, where the template actually moves, and refuses to let the vended
# surface change without the digest being updated in the same commit. Downstream
# repos pin that digest, so a silent change is a silent divergence in every one.
	@bash scripts/template-digest.sh
# The gap report is the document this whole bootstrap produces, and its summary
# is what gets read. It said high(0) while two high rows sat in a second table
# nobody had updated, and one of them hid a genuinely open item. The numbers are
# derived from the tables now and compared to what the prose claims.
	@bash scripts/gap-report-consistency.sh
# Nothing in this repo executed the template's workflows -- not actionlint, not the
# scaffold job's check-fast -- so an installer piped from a mutable branch shipped
# to every scaffold unnoticed. This reads them: remote scripts must be pinned to a
# commit (or checksummed) and tools must not install at @latest/@main.
	@bash scripts/template-workflow-pins.sh

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
selftests:
	@set -e; n=0; \
	  for ts in $(TEMPLATE_SELFTESTS); do [ -f "$$ts" ] || { echo "selftests: $$ts is missing: a vendored selftest nothing runs here is first exercised in someone else's CI" >&2; exit 2; }; done; \
	  for t in $(PROBES)/*-selftest.sh $(PROBES)/tests/*-selftest.sh scripts/tests/*-selftest.sh $(TEMPLATE_SELFTESTS); do \
	    [ -f "$$t" ] || continue; \
	    printf '  %-52s ' "$$(basename $$t)"; \
	    if bash "$$t" >/dev/null 2>&1; then echo "ok"; else echo "FAIL"; bash "$$t" 2>&1 | tail -20; exit 1; fi; \
	    n=$$((n+1)); \
	  done; \
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
evidence:
	@bash scripts/evidence-record.sh

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
