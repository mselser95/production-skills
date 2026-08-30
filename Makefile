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
.PHONY: help check-fast verify selftests lint actionlint gates tcb evidence template-digest

help:
	@echo "check-fast  the cheap local gate (lint + workflow validation + the repo's own probes)"
	@echo "verify      check-fast + every probe selftest + TCB verification"
	@echo "selftests   the probe selftests only"
	@echo "evidence    run every gate and write .prod/evidence/<sha>.json (dimension 11)"
	@echo "template-digest  recompute prod-new/TEMPLATE-DIGEST after a reviewed template change"

# ---- the cheap gate -------------------------------------------------------
check-fast: actionlint lint gates

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
# -S error only. The config.sh files are SOURCED, never executed, so they carry
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
# DEDUPED BY CONTENT, which is not a coverage compromise. install.sh mirrors the
# shared probes into all nine skills, so `verify-standard.sh` alone appears ten
# times byte-identically; shellcheck on identical bytes returns an identical
# verdict, so linting one representative per sha256 checks exactly the same set
# of distinct programs. Measured: 62 files -> 30s, deduped -> a third of that,
# and the file COUNT is still printed next to the unique count so a reader can
# see the ratio rather than take the saving on trust. If the two ever converge,
# the mirroring broke.
	@set -e; \
	  n=$$(find . -name '*.sh' -not -path './.wt/*' -not -path './.git/*' | grep -c .); \
	  if [ "$$n" -eq 0 ]; then echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2; fi; \
	  uniq_files=$$(find . -name '*.sh' -not -path './.wt/*' -not -path './.git/*' -print0 \
	    | xargs -0 shasum -a 256 | sort -k1,1 -u | awk '{ $$1=""; sub(/^ +/,""); print }'); \
	  u=$$(printf '%s\n' "$$uniq_files" | grep -c .); \
	  if [ "$$u" -eq 0 ]; then echo "lint: deduped to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi; \
	  printf '%s\n' "$$uniq_files" | tr '\n' '\0' | xargs -0 shellcheck -S error; \
	  echo "shellcheck: $$u unique script(s) of $$n clean at severity=error"

# The repo's own probes, run against the repo itself -- the half that was missing.
gates:
	@bash $(PROBES)/skills-static.sh
	@bash $(PROBES)/policy-coverage.sh
	@bash $(PROBES)/row-vacuity-sweep.sh
	@bash $(PROBES)/check-registries.sh
	@bash $(PROBES)/probe-wiring.sh
# scripts/ too, added after review noticed nothing covered it: evidence-record.sh
# and instantiate-template.sh are gates by any reasonable reading, and they lived
# outside the only check that asks whether a gate is driven.
	@bash $(PROBES)/probe-wiring.sh scripts
# The vended template's VERSION, and the producer side of the drift question.
# check-template-drift.sh runs in the SCAFFOLDED repo and answers "am I behind?";
# this runs here, where the template actually moves, and refuses to let the vended
# surface change without the digest being updated in the same commit. Downstream
# repos pin that digest, so a silent change is a silent divergence in every one.
	@bash scripts/template-digest.sh

# ---- the full gate --------------------------------------------------------
verify: check-fast selftests tcb

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
selftests:
	@set -e; n=0; \
	  for t in $(PROBES)/*-selftest.sh $(PROBES)/tests/*-selftest.sh; do \
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
