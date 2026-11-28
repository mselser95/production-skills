#!/usr/bin/env bash
# mutation-baseline-selftest.sh -- scripts/mutation-baseline.sh check mode must fail when the
# recorded **total** line differs from the sum of the recorded rows (it used to compare rows only).
# provenance: candidate
# ttl: 2027-01-20
# Drives the script through its MUTATION_BASELINE_FILE / MUTATION_BASELINE_SUITES overrides with a
# tiny fake suite, so it does not re-run the repo's selftests.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MB="${MB_SCRIPT:-$root/scripts/mutation-baseline.sh}"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "fake selftest: 3 case(s) passed"\n' > "$TMP/a-selftest.sh"
printf '#!/usr/bin/env bash\necho "fake selftest: 4 case(s) passed"\n' > "$TMP/b-selftest.sh"
export MUTATION_BASELINE_SELFTEST=1
export MUTATION_BASELINE_SUITES="$TMP/a-selftest.sh $TMP/b-selftest.sh" MUTATION_BASELINE_FILE="$TMP/base.md"

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-62s %s\n' "$1" "$3"
  else printf '  FAIL %-62s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }
run() { bash "$MB" "$@" >"$TMP/out" 2>&1; echo $?; }

check "--write records a baseline" 0 "$(run --write)"
check "check mode on a fresh baseline passes" 0 "$(run)"
check "recorded total equals the row sum (7)" 7 "$(grep -E '^\| \*\*total\*\*' "$TMP/base.md" | grep -oE '[0-9]+' | head -1)"

cp "$TMP/base.md" "$TMP/good.md"
sed 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **9** |/' "$TMP/good.md" > "$TMP/base.md"
check "NEG: total inflated above the row sum -> FAIL" 1 "$(run)"
grep -q 'recorded \*\*total\*\* (9) != sum' "$TMP/out" && r=named || r=unnamed
check "NEG: the failure names total vs sum" named "$r"
sed 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **5** |/' "$TMP/good.md" > "$TMP/base.md"
check "NEG: total deflated below the row sum -> FAIL" 1 "$(run)"
grep -v '^| \*\*total\*\*' "$TMP/good.md" > "$TMP/base.md"
check "NEG: missing total line -> FAIL" 1 "$(run)"
sed -e 's/^| `a-selftest.sh` | 3 |/| `a-selftest.sh` | 5 |/' -e 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **9** |/' "$TMP/good.md" > "$TMP/base.md"
check "a consistent baseline whose row FELL still FAILs (existing gate kept)" 1 "$(run)"

# Overrides without the test-mode flag are ignored (the real defaults are used) and a warning is
# printed. Runs a copy of the script in a throwaway root holding one marked suite, so the real
# suites (this one included) are never re-run.
FR="$TMP/fakeroot"; mkdir -p "$FR/scripts" "$FR/scripts/tests" "$FR/benchmarks"
cp "$MB" "$FR/scripts/mutation-baseline.sh"
printf '#!/usr/bin/env bash\necho "real-default suite: 2 case(s) passed"\n' > "$FR/scripts/tests/real-selftest.sh"
env -u MUTATION_BASELINE_SELFTEST bash "$FR/scripts/mutation-baseline.sh" --write >"$TMP/out2" 2>&1
check "NEG: overrides without the flag -> warning printed" 1 "$(grep -c 'set but ignored' "$TMP/out2")"
check "NEG: overrides without the flag -> real defaults used" 1 "$(grep -c 'real-selftest.sh' "$FR/benchmarks/mutation-baseline.md")"
check "NEG: overrides without the flag -> fake suites not recorded" 0 "$(grep -c 'a-selftest.sh' "$FR/benchmarks/mutation-baseline.md")"

# ---- the set of suites is compared too: a row with no suite and a suite with no row both FAIL ----
# provenance: candidate; ttl: 2027-02-27; pinning: true
# A suite dropped from the glob used to pass silently (its row just went unchecked) and a suite with
# no row was only a printed NEW. Both are failures now, and `--write` re-records exactly the suites
# that ran, so rows and suites agree after it.
printf '#!/usr/bin/env bash\necho "fake selftest: 6 case(s) passed"\n' > "$TMP/e-selftest.sh"
cp "$TMP/good.md" "$TMP/base.md"
check "set: rows and suites agree (a, b) -> passes (control)" 0 "$(run)"
MUTATION_BASELINE_SUITES="$TMP/a-selftest.sh" ; export MUTATION_BASELINE_SUITES
check "set: a recorded row (b) whose suite did not run -> FAIL" 1 "$(run)"
check "set: ...and the MISSING line names it" 1 "$(grep -c 'MISSING  b-selftest.sh' "$TMP/out")"
MUTATION_BASELINE_SUITES="$TMP/a-selftest.sh $TMP/b-selftest.sh $TMP/e-selftest.sh"; export MUTATION_BASELINE_SUITES
check "set: a suite that ran with no row (e) -> FAIL" 1 "$(run)"
check "set: ...and the NEW line names it" 1 "$(grep -c 'NEW      e-selftest.sh' "$TMP/out")"
check "set: --write re-records exactly the suites that ran (a, b, e)" 0 "$(run --write)"
check "set: ...three rows plus the total" 4 "$(grep -c '^| ' "$TMP/base.md" | awk '{print $1 - 1}')"
check "set: ...and check mode then passes" 0 "$(run)"
MUTATION_BASELINE_SUITES="$TMP/a-selftest.sh $TMP/b-selftest.sh"; export MUTATION_BASELINE_SUITES
check "set: the baseline now has a row (e) for a suite that is gone -> FAIL" 1 "$(run)"
cp "$TMP/good.md" "$TMP/base.md"

# ---- counts from the single recorded pass (scripts/run-once.sh) -------------------------------
# provenance: candidate; ttl: 2027-02-27; pinning: true
# `make selftests` runs each suite once and records its count; check mode reads that count when the
# line is vouched for (same suite, same canonical command, zero exit, same tree identity, same run) and
# executes the suite when it is not. Each fake suite logs its own execution, so "read" and "ran"
# are told apart by the log, not by the verdict alone. --write must never read the record. The fake
# suites take their count and exit code from files next to them (c.cases / c.rc: a suite run through
# scripts/run-once.sh no longer sees the caller's environment), so a recorded line is a REAL run of the suite.
RO="$root/scripts/run-once.sh"; EV="$TMP/results.tsv"; XL="$TMP/exec.log"
for s in c d; do printf '#!/usr/bin/env bash\necho x >> "%s"\necho "fake: $(cat "%s/%s.cases" 2>/dev/null || echo 4) case(s) passed"\nexit "$(cat "%s/%s.rc" 2>/dev/null || echo 0)"\n' "$XL" "$TMP" "$s" "$TMP" "$s" > "$TMP/$s-selftest.sh"; done
SU2="$TMP/c-selftest.sh $TMP/d-selftest.sh"
runr() { EVIDENCE_RESULTS="$EV" EVIDENCE_RUN_ID=mb1 MUTATION_BASELINE_SUITES="$SU2" MUTATION_BASELINE_FILE="$TMP/base2.md" bash "$MB" "$@" >"$TMP/out3" 2>&1; echo $?; }
rec() { EVIDENCE_RESULTS="$EV" EVIDENCE_RUN_ID=mb1 bash "$RO" --quiet --count "$@" >/dev/null 2>&1; }
runs() { local n; n=$(grep -c . "$XL" 2>/dev/null); echo "${n:-0}"; }
recsuite() { rec "selftest:$TMP/$1-selftest.sh" -- bash "$TMP/$1-selftest.sh"; }   # a real, recorded run of a fake suite
: > "$XL"; rm -f "$EV"
echo 99 > "$TMP/c.cases"; recsuite c; rm -f "$TMP/c.cases"; : > "$XL"
check "--write executes the suites and ignores a recorded count (two rows of 4)" "0 2 2" "$(runr --write) $(runs) $(grep -c '| 4 |' "$TMP/base2.md")"
: > "$XL"; rm -f "$EV"; recsuite c; : > "$XL"
check "check mode: a recorded count is read, only the unrecorded suite is executed" "0 1" "$(runr) $(runs)"
check "check mode: it says how many counts came from the single pass" 1 "$(grep -c '1 of 2 suite count(s) read from the single recorded pass' "$TMP/out3")"
: > "$XL"; rm -f "$EV"; echo 2 > "$TMP/c.cases"; recsuite c; rm -f "$TMP/c.cases"; recsuite d; : > "$XL"
check "check mode: the recorded count is what is compared (2 < 4 -> FELL, no suite executed)" "1 0" "$(runr) $(runs)"
check "check mode: ...and the FELL line names the suite" 1 "$(grep -c 'FELL     c-selftest.sh  4 -> 2' "$TMP/out3")"
: > "$XL"; awk -F'\t' -v OFS='\t' '{$9="0000000000000000000000000000000000000000+clean"; print}' "$EV" > "$EV.t"; mv "$EV.t" "$EV"
check "check mode: a count line with another tree identity is NOT trusted (suites executed, 4 >= 4)" "0 2" "$(runr) $(runs)"
: > "$XL"; rm -f "$EV"
rec "selftest:$TMP/c-selftest.sh" -- bash -c "CASES=2 bash $TMP/c-selftest.sh"; : > "$XL"
check "check mode: a count line recorded under another argv (bash -c ...) is NOT trusted" "0 2" "$(runr) $(runs)"
: > "$XL"; rm -f "$EV"
echo 2 > "$TMP/c.cases"; echo 1 > "$TMP/c.rc"; recsuite c; rm -f "$TMP/c.cases" "$TMP/c.rc"; : > "$XL"
check "check mode: a FAILED recorded run's count is NOT trusted (suites executed)" "0 2" "$(runr) $(runs)"
: > "$XL"; rm -f "$EV"; echo 2 > "$TMP/c.cases"; recsuite c; rm -f "$TMP/c.cases"; printf 'garbage\n' >> "$EV"; : > "$XL"
check "check mode: a malformed results file is NOT trusted (suites executed)" "0 2" "$(runr) $(runs)"
: > "$XL"; rm -f "$EV"
check "check mode: no results file at all -> both executed" "0 2" "$(runr) $(runs)"
: > "$XL"; rm -f "$EV"; recsuite c; : > "$XL"
(EVIDENCE_RESULTS="$EV" MUTATION_BASELINE_SUITES="$SU2" MUTATION_BASELINE_FILE="$TMP/base2.md" bash "$MB" >"$TMP/out3" 2>&1; echo $? >"$TMP/rc3")
check "check mode: with no run id nothing recorded is trusted (both executed)" "0 2" "$(cat "$TMP/rc3") $(runs)"

if (( FAILED > 0 )); then echo "mutation-baseline selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "mutation-baseline selftest: $CASES case(s) passed"
