#!/usr/bin/env bash
# acceptance-gap-selftest.sh — each verdict of acceptance-gap.sh shown on a
# fixture, plus non-vacuity: with the gap comparison disabled the BLOCKER cases
# must go RED (the selftest fails).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${GAP_PROBE:-$here/acceptance-gap.sh}"
[[ -f "$probe" ]] || probe="$here/../acceptance-gap.sh"
[[ -f "$probe" ]] || { echo "acceptance-gap selftest: probe not found beside or above $here"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-gap-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

# spec: AC-01..AC-04 visible, AC-05..AC-08 held_out
spec="$tmp/spec.yaml"
{
  echo "feature: transfers"
  echo "cases:"
  for n in 1 2 3 4 5 6 7 8; do
    echo "  - id: AC-0$n"
    if (( n <= 4 )); then echo "    lane: visible"; else echo "    lane: held_out"; fi
  done
} > "$spec"

res() { # file then "AC-NN VERDICT" lines
  local f="$tmp/$1"; shift; : > "$f"; local l; for l in "$@"; do echo "$l" >> "$f"; done; echo "$f"
}
V_OK=$(res v_ok "AC-01 PASS" "AC-02 PASS" "AC-03 PASS" "AC-04 PASS")
V_ONE_FAIL=$(res v_1f "AC-01 PASS" "AC-02 PASS" "AC-03 PASS" "AC-04 FAIL")
H_OK=$(res h_ok "AC-05 PASS" "AC-06 PASS" "AC-07 PASS" "AC-08 PASS")
H_ONE_FAIL=$(res h_1f "AC-05 PASS" "AC-06 PASS" "AC-07 PASS" "AC-08 FAIL")
H_TWO_FAIL=$(res h_2f "AC-05 PASS" "AC-06 PASS" "AC-07 FAIL" "AC-08 FAIL")
H_WRONG=$(res h_wrong "AC-01 PASS" "AC-05 PASS" "AC-06 PASS" "AC-07 PASS" "AC-08 PASS")
H_UNKNOWN=$(res h_unk "AC-05 PASS" "AC-06 PASS" "AC-07 PASS" "AC-08 PASS" "AC-99 PASS")
EMPTY=$(res empty)

run_case() { # name want_rc needle -- args
  local name="$1" want="$2" needle="$3"; shift 3
  local out rc
  out="$(bash "$probe" "$@" 2>&1)"; rc=$?
  if [[ $rc -eq $want && "$out" == *"$needle"* ]]; then pass=$((pass + 1))
  else echo "FAIL [$name]: rc=$rc want=$want, wanted '$needle' in: $out"; bad=$((bad + 1)); fi
}

run_case "all green on both lanes is OK" 0 "visible 4/4 held_out 4/4 gap=0.00 verdict=OK" "$spec" "$V_OK" "$H_OK"
run_case "one held-out FAIL with visible all green is a BLOCKER" 1 "held_out 3/4 gap=1.00 verdict=BLOCKER" "$spec" "$V_OK" "$H_ONE_FAIL"
run_case "a 2-case gap is a BLOCKER" 1 "held_out 2/4 gap=2.00 verdict=BLOCKER" "$spec" "$V_OK" "$H_TWO_FAIL"
run_case "equal imperfect rates are OK (gap 0)" 0 "visible 3/4 held_out 3/4 gap=0.00 verdict=OK" "$spec" "$V_ONE_FAIL" "$H_ONE_FAIL"
run_case "a held-out lane better than visible is OK" 0 "visible 3/4 held_out 4/4 gap=-1.00 verdict=OK" "$spec" "$V_ONE_FAIL" "$H_OK"
run_case "a visible id in the held-out file is refused" 2 "wrong results file" "$spec" "$V_OK" "$H_WRONG"
run_case "an unknown id is refused" 2 "AC-99 is not a case" "$spec" "$V_OK" "$H_UNKNOWN"
run_case "an empty results file is not a pass" 2 "nothing measured is not a pass" "$spec" "$V_OK" "$EMPTY"
run_case "an unreported spec case is not a pass" 2 "unmeasured is not a pass" "$spec" "$(res v_part "AC-01 PASS")" "$H_OK"

if (( pass == 0 )); then echo "acceptance-gap selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "acceptance-gap selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "acceptance-gap selftest: ok -- $pass case(s)"
