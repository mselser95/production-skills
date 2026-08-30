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
# Exit: 0 every gate passed · 1 a gate failed (recorded, then reported) · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

command -v python3 >/dev/null || { echo "evidence-record: python3 required for JSON escaping" >&2; exit 2; }

# The gates, each named as the dimension it answers. This list is the record's
# denominator: a gate missing from here is a dimension the record silently does
# not cover, so it is written once, next to the Makefile targets it mirrors.
GATES=(
  "ci-workflows-valid|make --no-print-directory actionlint"
  "shell-correctness|make --no-print-directory lint"
  "skills-structural|bash _shared/probes/skills-static.sh"
  "policy-coverage|bash _shared/probes/policy-coverage.sh"
  "row-vacuity|bash _shared/probes/row-vacuity-sweep.sh"
  "liability-registries|bash _shared/probes/check-registries.sh"
  "gates-are-driven|bash _shared/probes/probe-wiring.sh"
  "gates-are-driven-scripts|bash _shared/probes/probe-wiring.sh scripts"
  "template-version|bash scripts/template-digest.sh"
  "mutation-trend|bash scripts/mutation-baseline.sh"
  "gap-report-consistent|bash scripts/gap-report-consistency.sh"
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
  while IFS= read -r probe; do
    [[ -n "$probe" ]] || continue
    printf '%s\n' "${GATES[@]}" | grep -qF "$probe" || uncovered+=("$probe")
  done < <(sed -n '/^gates:/,/^$/p' Makefile | grep -vE '^[[:space:]]*#' \
             | grep -oE '[A-Za-z0-9_./$()-]+\.sh' | sed 's|.*/||' | sort -u)
  if (( ${#uncovered[@]} > 0 )); then
    echo "evidence-record: ${#uncovered[@]} gate(s) run by \`make gates\` are absent from this script's GATES list:" >&2
    printf '  uncovered: %s\n' "${uncovered[@]}" >&2
    echo "  The record would report a clean total while measuring less than the repo runs." >&2
    echo "  Add them to GATES, or the attestation is narrower than it looks." >&2
    exit 2
  fi
fi

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
# Everything else still counts, and is NAMED in the record: a bare
# tree_clean:false says the attestation is void and gives nobody a way to find
# out why. Measured 2026-08-29 on CI run 33284769197, whose artifact was
# dirty-d480857-*.json from a fresh checkout with no way to tell what touched it.
dirty_paths=$(git status --porcelain 2>/dev/null | grep -vE '^\?\? \.prod/evidence/?$' | head -20)
if [[ -n "$dirty_paths" ]]; then
  tree_clean=false
  record=".prod/evidence/dirty-${sha}-$(date -u +%Y%m%dT%H%M%SZ).json"
else
  tree_clean=true
  record=".prod/evidence/$sha.json"
fi
mkdir -p .prod/evidence || exit 2

passes=0; fails=0
declare -a LINES=()
for g in "${GATES[@]}"; do
  name="${g%%|*}"; cmd="${g#*|}"
  out=$(eval "$cmd" 2>&1); rc=$?
  # The last non-empty UNINDENTED line. Every gate here ends with its own summary
  # at column 0 ("52 keys -- 52 scored", "TCB verified: 309 files") and puts
  # detail underneath it indented. A plain `tail -1` captured the DETAIL instead:
  # probe-wiring's record read "excused: verify-standard.sh ..." rather than
  # "13 invoked + 1 declared-exception of 15", which is the number a reader
  # actually wants. Measured on the first run of this script.
  #
  # A record holding rc and no evidence is a boolean pretending to be an
  # attestation, so a gate that prints nothing on success is a gate to invoke
  # through its Makefile target instead -- `make actionlint` says "workflows
  # valid", bare actionlint says nothing at all.
  # make's own recursion chatter is filtered as well as suppressed. CI runs GNU
  # make 4.x, which prints `make[1]: Entering/Leaving directory '...'` around
  # every sub-make; those lines are unindented, so the rule above picked THEM as
  # the summary. Measured on run 33284769197: three of nine gates recorded
  # "make[1]: Leaving directory '/home/runner/work/production-skills/...'" as
  # their evidence -- the record failing at its one job while the step showed
  # green.
  #
  # --no-print-directory is passed to those gates too, but it is not enough on
  # its own to rely on: macOS ships GNU make 3.81, which does not emit the lines
  # at all, so the flag's effect CANNOT be observed on the machine this was
  # written on. A filter can be, and is, below.
  ev=$(printf '%s\n' "$out" \
        | grep -vE "^make(\\[[0-9]+\\])?: (Entering|Leaving) directory" \
        | grep -vE '^[[:space:]]*$|^[[:space:]]+' | tail -1)
  [[ -n "$ev" ]] || ev=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  [[ -n "$ev" ]] || ev="(gate produced no output; verdict from exit code $rc alone)"
  if (( rc == 0 )); then verdict=PASS; passes=$((passes+1)); else verdict=FAIL; fails=$((fails+1)); fi
  printf '  %-24s %-4s %s\n' "$name" "$verdict" "${ev:0:96}"
  LINES+=("    { \"gate\": $(jstr "$name"), \"command\": $(jstr "$cmd"), \"verdict\": \"$verdict\", \"evidence\": $(jstr "$ev") }")
done

{
  printf '{\n  "commit": "%s",\n' "$sha"
  printf '  "tree_clean": %s,\n' "$tree_clean"
  printf '  "dirty_paths": %s,\n' "$(jstr "$dirty_paths")"
  printf '  "generated_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "spec": "production.yaml",\n'
  printf '  "tier": "%s",\n' "$(grep -m1 -E '^[[:space:]]*tier:' production.yaml 2>/dev/null | tr -d ' ' | cut -d: -f2)"
  printf '  "toolchain_note": "verify-standard.sh is Go-only and refuses to run in this repo; these gates are its equivalent here",\n'
  printf '  "totals": { "pass": %d, "fail": %d },\n' "$passes" "$fails"
  printf '  "gates": [\n'
  first=1
  for l in "${LINES[@]}"; do [[ $first -eq 1 ]] || printf ',\n'; first=0; printf '%s' "$l"; done
  printf '\n  ]\n}\n'
} > "$record"

echo "evidence record: $record"
[[ "$tree_clean" == true ]] || echo "  (working tree DIRTY: this record is NOT an attestation for commit $sha)"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE -- $fails gate(s) failed; each is a finding, not a reason to soften the gate." >&2; exit 1; }
echo "VERDICT: COMPLETE -- ${passes}/${#GATES[@]} gates passed"
