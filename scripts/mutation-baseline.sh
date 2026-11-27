#!/usr/bin/env bash
# mutation-baseline.sh — record how many mutations this repo demonstrates, and
# refuse to let that number quietly fall.
#
# WHAT THE BASELINE IS, and what it deliberately is not.
#
# The standard asks for "a baseline artifact, refreshed; trend, not a gate". In a
# Go repo that is a mutation score from a mutation-testing tool. There is no such
# tool for shell, and inventing a percentage would be worse than none.
#
# What this repo actually has is stronger than a score and weaker than nothing
# measured it: TEN selftests, each of which is a battery of fixtures where one
# property is FALSE and the subject must go red. That is mutation testing done by
# hand and committed -- 272 cases as of 2026-08-30. `make selftests` executes
# every one on every commit.
#
# So the baseline is the CASE COUNT PER SELFTEST, derived by running them rather
# than typed. And the one thing it gates on is the direction that matters:
#
#   A COUNT MUST NEVER FALL. Cases disappear silently -- a fixture deleted while
#   "simplifying", a loop that stops early, a rename that makes a case
#   unreachable -- and the suite still reports "ok". Growth is free; shrinkage
#   needs a human to say so.
#
# It does NOT gate on a target number. There is no correct number of cases, and a
# floor invented here would be a threshold nobody derived.
#
# Usage:
#   mutation-baseline.sh          compare against the recorded counts (gate)
#   mutation-baseline.sh --write  re-record, after a deliberate change
# Exit: 0 no regression · 1 a count fell · 2 refused to answer
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

# MUTATION_BASELINE_FILE / MUTATION_BASELINE_SUITES are honoured ONLY with
# MUTATION_BASELINE_SELFTEST=1 (set by scripts/tests/mutation-baseline-selftest.sh). A stray
# export would otherwise make `make mutation` pass over fake suites.
if [[ "${MUTATION_BASELINE_SELFTEST:-}" != 1 ]]; then
  if [[ -n "${MUTATION_BASELINE_FILE:-}${MUTATION_BASELINE_SUITES:-}" ]]; then
    echo "mutation-baseline: WARNING MUTATION_BASELINE_FILE/MUTATION_BASELINE_SUITES are set but ignored (selftest-only)" >&2
  fi
  unset MUTATION_BASELINE_FILE MUTATION_BASELINE_SUITES
fi
BASELINE="${MUTATION_BASELINE_FILE:-benchmarks/mutation-baseline.md}"

# Counts come from RUNNING each selftest, never from grepping it for `check`
# calls: a case that is present in the source and never reached is exactly what
# this is supposed to notice, and a static count would report it as covered.
#
# "Running" no longer means a second, third and fourth run of every suite per CI job.
# `make selftests` already runs each suite once, through scripts/run-once.sh, which
# stores the suite's own count next to its exit code. CHECK mode takes the count from
# that line when run-once.sh vouches for it -- the same suite path, the same command
# string, a zero exit, the same tree identity (HEAD, clean or dirty content hash), the
# same run id, within the age limit, no conflicting duplicate -- and executes the suite
# itself when there is no such line. A count is therefore still the number a suite
# EXECUTED, only measured once. --write is a maintainer action and always executes.
declare -a NAMES=() COUNTS=() TID=() TCNT=()
total=0; nt=0; from_pass=0
if [[ "${1:-}" != "--write" ]]; then
  while IFS=$'\t' read -r cid ccmd ccnt; do
    [[ "$cid" == selftest:* && "$ccmd" == "bash ${cid#selftest:}" && "$ccnt" =~ ^[0-9]+$ ]] || continue
    TID[nt]="${cid#selftest:}"; TCNT[nt]="$ccnt"; nt=$((nt+1))
  done < <(bash scripts/run-once.sh counts 2>/dev/null)
fi
# MUTATION_BASELINE_SUITES (selftest only) is a word list of suite paths
SUITES=(_shared/probes/*-selftest.sh _shared/probes/tests/*-selftest.sh scripts/tests/*-selftest.sh)
[[ -n "${MUTATION_BASELINE_SUITES:-}" ]] && read -ra SUITES <<<"$MUTATION_BASELINE_SUITES"
for t in "${SUITES[@]}"; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  n=""; i=0
  while (( i < nt )); do
    if [[ "${TID[i]}" == "$t" ]]; then n="${TCNT[i]}"; from_pass=$((from_pass+1)); break; fi
    i=$((i+1))
  done
  if [[ -z "$n" ]]; then
    out=$(bash "$t" 2>&1); rc=$?
    if (( rc != 0 )); then
      echo "mutation-baseline: $name FAILED (rc=$rc) -- counting cases from a failing" >&2
      echo "  suite would record a number nobody can trust. Fix the selftest first." >&2
      exit 2
    fi
    # Every selftest here ends with a summary carrying its own case count. Take the
    # first integer of the last line that has one, so a suite that changes its
    # wording still reports.
    # The number that PRECEDES `ok` or `case`, anywhere on the line -- suites word
    # their summary differently ("12 ok, 0 failed", "60 case(s), every verdict...",
    # "probe-self gate selftest: 29 ok"). Anchoring at line start missed the last
    # of those, and matching any integer would have picked up the "0 failed".
    # run-once.sh carries the same expression for the recorded path;
    # scripts/tests/run-once-selftest.sh pins that the two agree.
    n=$(printf '%s\n' "$out" | grep -oE '[0-9]+ (ok|case)' | tail -1 | grep -oE '^[0-9]+')
    [[ -n "$n" ]] || { echo "mutation-baseline: cannot read a case count from $name" >&2; exit 2; }
  fi
  NAMES+=("$name"); COUNTS+=("$n"); total=$((total + n))
done

if (( ${#NAMES[@]} == 0 )); then
  echo "mutation-baseline: found ZERO selftests -- a baseline over nothing records nothing" >&2
  exit 2
fi

if [[ "${1:-}" == "--write" ]]; then
  {
    echo "# Mutation baseline"
    echo
    echo "Generated by \`scripts/mutation-baseline.sh --write\`. Do not hand-edit."
    echo
    echo "Each selftest is a battery of fixtures where one property is FALSE and the"
    echo "subject must go red. The count is what that suite actually EXECUTED, not what"
    echo "its source appears to contain -- a case present and unreachable is precisely"
    echo "what a static count would miss."
    echo
    echo "**This is a trend, not a target.** The gate fires in one direction only: a"
    echo "count that FALLS. There is no correct number of cases, and a floor invented"
    echo "here would be a threshold nobody derived."
    echo
    echo "| selftest | cases |"
    echo "|---|---|"
    for i in "${!NAMES[@]}"; do printf '| `%s` | %s |\n' "${NAMES[$i]}" "${COUNTS[$i]}"; done
    printf '| **total** | **%d** |\n' "$total"
  } > "$BASELINE"
  echo "mutation-baseline: wrote $BASELINE -- ${#NAMES[@]} suite(s), $total case(s)"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "mutation-baseline: no $BASELINE -- nothing to compare against." >&2
  echo "  Run: make mutation-baseline" >&2
  exit 1
fi

# The recorded `**total**` line must equal the sum of the recorded rows. Per-suite comparison
# alone lets a hand-edited (or half-regenerated) total drift from its rows unnoticed.
rec_sum=$(grep -E '^\| `[^`]+` \|' "$BASELINE" | awk -F'|' '{gsub(/ /,"",$3); s+=$3} END {print s+0}')
rec_total=$(grep -E '^\| \*\*total\*\* \|' "$BASELINE" | awk -F'|' '{gsub(/[ *]/,"",$3); print $3}')
if [[ -z "$rec_total" ]]; then
  echo "mutation-baseline: $BASELINE has no **total** line -- cannot verify it against the rows" >&2; exit 1
elif (( rec_total != rec_sum )); then
  echo "mutation-baseline: recorded **total** ($rec_total) != sum of recorded rows ($rec_sum) in $BASELINE." >&2
  echo "  Do not hand-edit it; run \`make mutation-baseline\`." >&2; exit 1
fi

fell=0
for i in "${!NAMES[@]}"; do
  was=$(grep -E "^\| \`${NAMES[$i]}\` \|" "$BASELINE" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  [[ -n "$was" ]] || { echo "  NEW      ${NAMES[$i]} (${COUNTS[$i]} cases) -- not in the baseline yet"; continue; }
  if (( COUNTS[i] < was )); then
    echo "  FELL     ${NAMES[$i]}  $was -> ${COUNTS[$i]} case(s)" >&2; fell=$((fell+1))
  fi
done

if (( fell > 0 )); then
  echo "mutation-baseline: $fell suite(s) demonstrate FEWER mutations than recorded." >&2
  echo "  Cases disappear silently and the suite still says ok. If the removal was" >&2
  echo "  deliberate, say so and run \`make mutation-baseline\`; if it was not, the" >&2
  echo "  coverage this repo claims just shrank." >&2
  exit 1
fi

(( from_pass == 0 )) || echo "mutation-baseline: $from_pass of ${#NAMES[@]} suite count(s) read from the single recorded pass, the rest executed"
echo "mutation-baseline: ${#NAMES[@]} suite(s), $total case(s), none fell"
