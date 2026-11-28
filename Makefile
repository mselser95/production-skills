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
.PHONY: help check-fast verify selftests lint actionlint gates tcb evidence template-digest mutation mutation-baseline invariants token-report token-baseline skill-weight-baseline eval eval-live db-test

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
# One line: the recorder (scripts/evidence-record.sh) owns the gate list and runs each gate
# once, in a clean environment, actionlint and lint first, then `gates`. The Makefile is only
# the caller; nothing reads it to decide what is attested.
check-fast:
	@bash scripts/evidence-record.sh --run check-fast

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
# The list lives in scripts/evidence-record.sh (GATES, group `main`), with the reason each gate
# exists; this line only calls it. It stops at the first failing gate, as the recipe lines did.
gates:
	@bash scripts/evidence-record.sh --run gates

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
# THE SUITE LIST (the globs, the template-only suites and the REQUIRED ones that must exist and
# must have run) lives in ONE place, scripts/evidence-record.sh, which executes it: each suite
# once through scripts/run-once.sh, one line per suite with its case count, which
# mutation-baseline.sh reads instead of running the suite again. There is NO aggregate line:
# `make evidence` derives the `probe-selftests` gate from the per-suite lines of the same run.
selftests:
	@bash scripts/evidence-record.sh --run selftests

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
# --attest: a gate that already ran in this job through scripts/run-once.sh (which every
# gate of check-fast, gates and selftests does), on the same command string and the same
# tree, is ATTESTED from its recorded line instead of being executed again; anything else is
# executed here. See evidence-record.sh.
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
