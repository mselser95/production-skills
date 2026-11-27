#!/usr/bin/env bash
# evidence-record.sh — one record per commit answering "under what standard was
# this commit held?", for the framework repo itself.
#
# WHY THIS EXISTS
#
# Dimension 11 (reproducibility) asks for a per-commit evidence record produced
# by CI on a clean tree. Every repo scaffolded from prod-new gets one, written by
# verify-standard.sh. This repo got none — verify-standard.sh is Go-only and
# refuses to run here, so the dimension arrived with its mechanism attached to a
# probe that cannot execute, and nothing filled the gap. Ephemeral CI stdout is
# not a record: ninety days later the log is gone and the question is
# unanswerable without archaeology.
#
# THE FILENAME IS AN ATTESTATION, and that rule is inherited deliberately. A
# record named <sha>.json means "measured on exactly that commit". Stamping
# `git rev-parse HEAD` onto a run measured on a DIRTY tree produces a record
# named after a commit it was never measured on, and that has already happened
# once in this org: a committed <sha>.json claimed a PASS for a probe row that
# did not exist in that commit's tree. A plausible green attestation for a state
# that never passed is worse than no record.
#
# So a dirty tree gets a name that cannot be mistaken for an attestation, and
# carries tree_clean:false.
#
# ATTEST MODE (`--attest`, what `make evidence` passes)
#
# This record used to EXECUTE every gate below, although almost all of them had
# already run earlier in the same CI job (`make check-fast`, `make selftests`):
# 484 of the job's 847 seconds, spent proving what was already proven. The property
# the repetition protected, written into the workflow next to this step, was that a
# record assembled from another step's exit codes attests to what the YAML says ran,
# not to what ran. It is kept by a different mechanism: the Makefile runs each gate
# through scripts/run-once.sh, which is the thing that executes it and writes one line
# (command string, exit code, output hash, tree identity, run id, time). In attest mode a
# gate is taken from that file ONLY when a well-formed line exists for the same id, the
# same command string, the same tree identity (HEAD, clean or dirty, and the dirty
# content hash) and the same run, within the age limit, with no conflicting duplicate.
# Anything else -- no file, an empty one, a malformed one, another HEAD, another command
# string, a dirtied tree, conflicting lines -- falls back to EXECUTING the gate here, as
# before, and the record says so. A recorded non-zero exit makes the record fail exactly
# as an executed failure does. Every gate in the record carries `source`: executed or
# attested, and an attested one names the results-file line it came from.
#
# Usage: evidence-record.sh [--attest] [--check-wiring]
#   --check-wiring  run the two guards below and stop (exit 0 = consistent)
# Exit: 0 every gate passed · 1 a gate failed (recorded, then reported) · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

attest=0; check_wiring=0
for a in "$@"; do
  case "$a" in
    --attest) attest=1 ;;
    --check-wiring) check_wiring=1 ;;
    *) echo "evidence-record: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "evidence-record: python3 required for JSON escaping" >&2; exit 2; }

# The gates, each named as the dimension it answers. This list is the record's
# denominator: a gate missing from here is a dimension the record silently does
# not cover, so it is written once, next to the Makefile targets it mirrors.
GATES=(
  "ci-workflows-valid|make --no-print-directory actionlint"
  "shell-correctness|make --no-print-directory lint"
  "skills-structural|bash _shared/probes/skills-static.sh"
  "agents-token-budget|bash _shared/probes/agents-budget.sh"
  "skill-weight|bash _shared/probes/skill-weight.sh"
  "policy-coverage|bash _shared/probes/policy-coverage.sh"
  "row-vacuity|bash _shared/probes/row-vacuity-sweep.sh"
  "row-catalogue|bash _shared/probes/row-catalogue.sh"
  "liability-registries|bash _shared/probes/check-registries.sh"
  "gate-hygiene|bash prod-new/template/scripts/gate-hygiene-fitness.sh _shared/probes prod-new/template/scripts"
  "gates-are-driven|bash _shared/probes/probe-wiring.sh"
  "gates-are-driven-scripts|bash _shared/probes/probe-wiring.sh scripts"
  "template-version|bash scripts/template-digest.sh"
  "mutation-trend|bash scripts/mutation-baseline.sh"
  "gap-report-consistent|bash scripts/gap-report-consistency.sh"
  "template-workflow-pins|bash scripts/template-workflow-pins.sh"
  "ratified-invariants|make --no-print-directory invariants"
  "probe-selftests|make --no-print-directory selftests"
  "tcb-integrity|bash install.sh --verify"
)
(( ${#GATES[@]} > 0 )) || { echo "evidence-record: ZERO gates declared -- a record over nothing attests nothing" >&2; exit 2; }

# THE LIST ABOVE IS THIS RECORD'S DENOMINATOR, so it is cross-checked against the
# Makefile rather than trusted. It rotted on its first day: `template-digest.sh`
# was wired into `make gates` and this array still had nine entries, so the
# artifact said "9/9 gates passed" over a repo with ten. A record that reports a
# clean total while silently covering less than the repo runs is the exact defect
# every probe here exists to refuse, and it was in the recorder itself.
#
# Compare by script basename: anything `make gates` executes must appear in some
# gate command above. Makefile-internal targets (lint, actionlint, selftests) are
# covered by their own entries and are not script invocations, so they are not
# part of this comparison.
if [[ -r Makefile ]]; then
  uncovered=()
  # capture, then match: `printf | grep -qF` under pipefail reads a MATCH as a miss
  # when the writer takes SIGPIPE (gate-hygiene-fitness GREPQ-UNDER-PIPEFAIL)
  gates_text=$(printf '%s\n' "${GATES[@]}")
  while IFS= read -r probe; do
    [[ -n "$probe" ]] || continue
    grep -qF "$probe" <<<"$gates_text" || uncovered+=("$probe")
  done < <(sed -n '/^gates:/,/^$/p' Makefile | grep -vE '^[[:space:]]*#' \
             | grep -oE '[A-Za-z0-9_./$()-]+\.sh' | sed 's|.*/||' | grep -vx 'run-once.sh' | sort -u)
  if (( ${#uncovered[@]} > 0 )); then
    echo "evidence-record: ${#uncovered[@]} gate(s) run by \`make gates\` are absent from this script's GATES list:" >&2
    printf '  uncovered: %s\n' "${uncovered[@]}" >&2
    echo "  The record would report a clean total while measuring less than the repo runs." >&2
    echo "  Add them to GATES, or the attestation is narrower than it looks." >&2
    exit 2
  fi
fi

# SECOND GUARD: attesting only works when `make gates` runs a gate under the SAME id
# and command string this list holds for it. A drift between the two is not unsafe
# (the gate is simply not attested and runs twice) but it silently brings the double
# execution back, so it is refused here rather than discovered in the job's duration.
# `make -n` prints the expanded recipe without running it (gates uses no $(MAKE)).
if [[ -r Makefile ]] && grep -qE '^gates:' Makefile; then
  mk_plan=$(make --no-print-directory -n gates 2>&1) || {
    echo "evidence-record: \`make -n gates\` failed, cannot cross-check the run-once ids:" >&2
    printf '%s\n' "$mk_plan" | tail -5 >&2; exit 2; }
  drifted=()
  while IFS= read -r line; do
    [[ "$line" == "bash scripts/run-once.sh "* ]] || continue
    rest=${line#bash scripts/run-once.sh }
    [[ "$rest" == *" -- "* ]] || continue
    rid=${rest%% -- *}; rcmd=${rest#* -- }
    for g in "${GATES[@]}"; do
      [[ "${g%%|*}" == "$rid" ]] || continue
      [[ "${g#*|}" == "$rcmd" ]] || drifted+=("$rid: make gates runs [$rcmd], GATES holds [${g#*|}]")
    done
  done <<<"$mk_plan"
  if (( ${#drifted[@]} > 0 )); then
    echo "evidence-record: ${#drifted[@]} gate(s) run by \`make gates\` under a different command string than GATES:" >&2
    printf '  drift: %s\n' "${drifted[@]}" >&2
    echo "  Attest would never match them: they would run twice again. Make the two strings identical." >&2
    exit 2
  fi
fi
(( check_wiring == 0 )) || { echo "evidence-record: wiring consistent (${#GATES[@]} gates)"; exit 0; }

jstr() { printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'; }

sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# WHAT is dirty, not just THAT it is. The first version recorded a bare
# tree_clean:false, and the CI run that produced it was unactionable: the record
# said the attestation was void and gave nobody a way to find out why. Measured
# 2026-08-29 on run 33284769197 -- a fresh CI checkout produced
# dirty-d480857-*.json and there was no way to tell from the artifact what had
# touched the tree.
# .prod/evidence is EXCLUDED from the cleanliness question, and that is not a
# convenience. It is this script's own output directory: gitignored, created by
# this run, and present precisely because the record is being written. Letting it
# count means the record's existence is what voids the record -- the second
# invocation could never produce an attestation, and the first only by accident.
# Reproduced locally: with the tree otherwise clean, `git status --porcelain`
# returned exactly `?? .prod/evidence/`.
#
# .evidence is the same kind of thing: the results file run-once.sh appends to.
#
# Everything else still counts, and is NAMED in the record: a bare
# tree_clean:false says the attestation is void and gives nobody a way to find
# out why. Measured 2026-08-29 on CI run 33284769197, whose artifact was
# dirty-d480857-*.json from a fresh checkout with no way to tell what touched it.
dirty_paths=$(git status --porcelain 2>/dev/null | grep -vE '^\?\? (\.prod/evidence|\.evidence)/?$' | head -20)
if [[ -n "$dirty_paths" ]]; then
  tree_clean=false
  record=".prod/evidence/dirty-${sha}-$(date -u +%Y%m%dT%H%M%SZ).json"
else
  tree_clean=true
  record=".prod/evidence/$sha.json"
fi
mkdir -p .prod/evidence || exit 2

passes=0; fails=0; n_exec=0; n_att=0
declare -a LINES=()
for g in "${GATES[@]}"; do
  name="${g%%|*}"; cmd="${g#*|}"
  src=executed; why=""; rline=null; from=""
  if (( attest )); then
    res=$(bash scripts/run-once.sh resolve "$name" "$cmd")
    IFS=$'\t' read -r kind r1 r2 r3 r4 r5 r6 <<<"$res"
    if [[ "$kind" == attested ]]; then
      src=attested; rc=$r1; rline=$r2; ev=$r6
      from=$(printf '{ "results_file": %s, "line": %s, "duration_ms": %s, "output_sha256": "%s", "recorded_utc": "%s" }' \
        "$(jstr "${EVIDENCE_RESULTS:-.evidence/results.tsv}")" "$r2" "$r3" "$r4" "$r5")
    else
      why="${r1:-unresolved}"
    fi
  fi
  if [[ "$src" == executed ]]; then
    out=$(eval "$cmd" 2>&1); rc=$?
    # the one-line evidence is cut by run-once.sh's summary, the same code that wrote
    # the evidence column of the results file, so both sources read alike
    ev=$(printf '%s\n' "$out" | bash scripts/run-once.sh summary "$rc")
    n_exec=$((n_exec+1))
  else
    n_att=$((n_att+1))
  fi
  if (( rc == 0 )); then verdict=PASS; passes=$((passes+1)); else verdict=FAIL; fails=$((fails+1)); fi
  printf '  %-24s %-4s %-8s %s\n' "$name" "$verdict" "$src" "${ev:0:84}"
  extra=""
  [[ -z "$from" ]] || extra=", \"attested_from\": $from"
  [[ -z "$why" ]] || extra="$extra, \"why_executed\": $(jstr "$why")"
  LINES+=("    { \"gate\": $(jstr "$name"), \"command\": $(jstr "$cmd"), \"verdict\": \"$verdict\", \"source\": \"$src\", \"results_line\": $rline, \"evidence\": $(jstr "$ev")${extra} }")
done

{
  printf '{\n  "commit": "%s",\n' "$sha"
  printf '  "tree_clean": %s,\n' "$tree_clean"
  printf '  "dirty_paths": %s,\n' "$(jstr "$dirty_paths")"
  printf '  "generated_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "spec": "production.yaml",\n'
  printf '  "tier": "%s",\n' "$(grep -m1 -E '^[[:space:]]*tier:' production.yaml 2>/dev/null | tr -d ' ' | cut -d: -f2)"
  printf '  "toolchain_note": "verify-standard.sh is Go-only and refuses to run in this repo; these gates are its equivalent here",\n'
  printf '  "attest_mode": %s,\n' "$([[ $attest == 1 ]] && echo true || echo false)"
  printf '  "totals": { "pass": %d, "fail": %d, "executed": %d, "attested": %d },\n' "$passes" "$fails" "$n_exec" "$n_att"
  printf '  "gates": [\n'
  first=1
  for l in "${LINES[@]}"; do [[ $first -eq 1 ]] || printf ',\n'; first=0; printf '%s' "$l"; done
  printf '\n  ]\n}\n'
} > "$record"

echo "evidence record: $record"
[[ "$tree_clean" == true ]] || echo "  (working tree DIRTY: this record is NOT an attestation for commit $sha)"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE -- $fails gate(s) failed; each is a finding, not a reason to soften the gate." >&2; exit 1; }
echo "VERDICT: COMPLETE -- ${passes}/${#GATES[@]} gates passed (${n_att} attested, ${n_exec} executed)"
