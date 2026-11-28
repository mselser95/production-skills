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

# -print0/xargs -0 is load-bearing and was learned the hard way: passing an
# unquoted $(files) variable to shellcheck under zsh does NOT word-split, so
# every path arrives as ONE argument and shellcheck dies with "File name too
# long" -- exit 2, no findings, and a reader who sees a filename list scrolling
# past reads it as a report. A lint that cannot run must not look like a lint
# that found nothing.
#
# -S warning, RAISED from -S error on 2026-08-30 after the warning tier was
# classified and emptied: 67 findings -> 0. Raising it is the point. A tier
# nobody enforces drifts back, and the 67 had accumulated precisely because
# the gate stopped at error -- among them one genuinely dead expiry variable,
# a LOC count that miscounts filenames with spaces, and 60 unguarded `cd`s in
# a selftest, each followed by an assertion that would have measured the wrong
# tree.
#
# The config.sh files are SOURCED, never executed, so they carry
# `# shellcheck shell=bash` instead of a shebang rather than being excluded:
# excluding them would take the nine files most likely to be hand-edited out of
# the only check that reads them.
# `set -e` on the FIRST line of this recipe is the load-bearing character, and
# it is here because the recipe without it was decorative. Measured 2026-08-29,
# ten minutes after this file was written: appending a genuine `if [ "$$x" = ];`
# to a probe made `shellcheck -S error` exit 1 on its own, and `make lint`
# STAYED GREEN. A backslash-continued recipe is ONE shell command to make, so
# only the LAST element's status is graded -- and the last element was the
# `echo` that announces success, which cannot fail.
#
# A gate whose success message is also the thing make grades is not a gate. It
# was caught by mutating it rather than by reading it, which is the only reason
# it is not still sitting here reporting 62 clean scripts forever. Every other
# multi-line recipe in this file is `set -e` or one-command-per-line for the
# same reason.
lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; }
#
# TRACKED FILES ONLY (`git ls-files`), and that alignment was itself a finding.
# The gate used to walk the working tree while CI lints what the clone contains,
# so the two ran over different sets: raising this to -S warning turned the local
# gate red on gitignored per-user `config.sh` files that CI has never seen, and a
# gate that fails only on the author's machine is one they learn to bypass.
#
# `git ls-files` also covers a NEW file the moment it is staged, which is exactly
# when the pre-commit hook runs -- so nothing being committed escapes the lint.
# What it deliberately skips is uncommitted scratch and per-user config, neither
# of which this gate is protecting anyone from.
#
# DEDUPED BY CONTENT, which is not a coverage compromise. install.sh mirrors the
# shared probes into all nine skills, so `verify-standard.sh` alone appears ten
# times byte-identically; shellcheck on identical bytes returns an identical
# verdict, so linting one representative per sha256 checks exactly the same set
# of distinct programs. Measured: 62 files -> 30s, deduped -> a third of that,
# and the file COUNT is still printed next to the unique count so a reader can
# see the ratio rather than take the saving on trust. If the two ever converge,
# the mirroring broke.
	@set -e; \
	  n=$$(git ls-files '*.sh' | grep -c .); \
	  if [ "$$n" -eq 0 ]; then echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2; fi; \
	  uniq_files=$$(git ls-files '*.sh' -z \
	    | xargs -0 shasum -a 256 | sort -k1,1 -u | awk '{ $$1=""; sub(/^ +/,""); print }'); \
	  u=$$(printf '%s\n' "$$uniq_files" | grep -c .); \
	  if [ "$$u" -eq 0 ]; then echo "lint: deduped to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi; \
	  printf '%s\n' "$$uniq_files" | tr '\n' '\0' | xargs -0 shellcheck -S warning; \
	  echo "shellcheck: $$u unique script(s) of $$n clean at severity=warning"

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
