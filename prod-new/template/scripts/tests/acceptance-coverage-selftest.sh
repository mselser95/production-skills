#!/usr/bin/env bash
# acceptance-coverage-selftest.sh — every rule in acceptance-coverage.sh shown
# firing on a fixture where its property is false, and a valid fixture passing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/acceptance-coverage.sh"
# vendored layout: scripts/tests/<selftest> beside scripts/<probe>
[[ -f "$probe" ]] || probe="$here/../acceptance-coverage.sh"
[[ -f "$probe" ]] || { echo "acceptance-coverage selftest: probe not found beside or above $here"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-coverage-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

ROWS="happy_path input_classes declared_errors authorization idempotency_retry state_transitions ordering_concurrency durability_restart compatibility feature_interaction"

# mk <name> ; a valid repo: approved spec, 2 cases, every row filled, 2 tests
mk() {
  local r="$tmp/$1"; mkdir -p "$r/acceptance" "$r/tests"
  {
    echo "feature: transfers"
    echo "intent: move funds between accounts"
    echo "approved_by: mati"
    echo "approved_at: 2026-10-02"
    echo "surface: [POST /v1/transfers]"
    echo "matrix:"
    for row in $ROWS; do echo "  $row: [AC-01]"; done
    echo "  observability: [AC-02]"
    echo "cases:"
    for n in 01 02; do
      echo "  - id: AC-$n"
      echo "    given: an account with 10"
      echo "    when: POST a transfer of 5"
      echo "    then: 201 and balance 5"
      echo "    observe: response"
      echo "    mutation: skip the balance debit"
    done
  } > "$r/acceptance/transfers.yaml"
  printf '// provenance: derived\n// verifies: acceptance:transfers/AC-01\n' > "$r/tests/a_test.go"
  printf '// provenance: derived\n// verifies: acceptance:transfers/AC-02\n' > "$r/tests/b_test.go"
  echo "$r"
}

run_case() { # name want_rc want_substring -- args...
  local name="$1" want="$2" needle="$3"; shift 3
  local out rc
  out="$(bash "$probe" "$@" 2>&1)"; rc=$?
  if [[ $rc -eq $want && "$out" == *"$needle"* ]]; then pass=$((pass + 1))
  else echo "FAIL [$name]: rc=$rc want=$want, wanted '$needle' in: $out"; bad=$((bad + 1)); fi
}
S() { echo "$1/acceptance/transfers.yaml"; }

r=$(mk ok);        run_case "a complete, approved, traced spec passes" 0 "2 case(s) traced" "$(S "$r")" "$r"

r=$(mk pending);   sed -i.bak 's/^approved_by: mati/approved_by: pending/' "$(S "$r")"
run_case "pending approval fails the full check" 1 "approved_by is pending" "$(S "$r")" "$r"
run_case "pending approval passes --spec-only" 0 "spec only" --spec-only "$(S "$r")" "$r"

r=$(mk norow);     sed -i.bak '/^  compatibility:/d' "$(S "$r")"
run_case "a missing matrix row fails" 1 "row 'compatibility' is missing" "$(S "$r")" "$r"

r=$(mk emptyrow);  sed -i.bak 's/^  authorization: .*/  authorization: []/' "$(S "$r")"
run_case "an empty matrix row fails" 1 "row 'authorization' is empty" "$(S "$r")" "$r"

r=$(mk nareason);  sed -i.bak 's/^  durability_restart: .*/  durability_restart: {na: ""}/' "$(S "$r")"
run_case "na without a reason fails" 1 "na with no reason" "$(S "$r")" "$r"

r=$(mk naok);      sed -i.bak 's/^  durability_restart: .*/  durability_restart: {na: "stateless read path"}/' "$(S "$r")"
run_case "na WITH a reason passes" 0 "(1 na)" "$(S "$r")" "$r"

r=$(mk nomut);     perl -0pi -e 's/    mutation: skip the balance debit\n//' "$(S "$r")"
run_case "a case with no mutation fails" 1 "AC-01 has no mutation" "$(S "$r")" "$r"

r=$(mk badobs);    perl -0pi -e 's/observe: response/observe: internal_struct/' "$(S "$r")"
run_case "observe outside the surface vocabulary fails" 1 "observe 'internal_struct'" "$(S "$r")" "$r"

r=$(mk orphan);    sed -i.bak 's/^  observability: .*/  observability: [AC-01]/' "$(S "$r")"
run_case "a case in no matrix row fails" 1 "AC-02 is in no matrix row" "$(S "$r")" "$r"

r=$(mk unknown);   sed -i.bak 's/^  happy_path: .*/  happy_path: [AC-01, AC-09]/' "$(S "$r")"
run_case "a matrix row citing a non-case fails" 1 "cites AC-09, which is not a case" "$(S "$r")" "$r"

r=$(mk untested);  rm "$r/tests/b_test.go"
run_case "a case with no test fails" 1 "AC-02 has no test" "$(S "$r")" "$r"

r=$(mk phantom);   printf '// verifies: acceptance:transfers/AC-07\n' > "$r/tests/c_test.go"
run_case "a test citing an undefined case fails" 1 "the spec does not define" "$(S "$r")" "$r"

r=$(mk other);     printf '// verifies: acceptance:withdrawals/AC-07\n' > "$r/tests/c_test.go"
run_case "another feature's ids are not this spec's business" 0 "2 case(s) traced" "$(S "$r")" "$r"

r=$(mk dup);       perl -0pi -e 's/id: AC-02/id: AC-01/' "$(S "$r")"
run_case "a duplicated id fails" 1 "AC-01 is duplicated" "$(S "$r")" "$r"

r=$(mk nosurface); sed -i.bak 's/^surface: .*/surface: []/' "$(S "$r")"
run_case "an empty surface fails" 1 "surface is empty" "$(S "$r")" "$r"

r=$(mk nocases);   perl -0pi -e 's/cases:\n(.|\n)*/cases: []\n/' "$(S "$r")"
run_case "zero cases is not a pass" 2 "zero cases" "$(S "$r")" "$r"

run_case "no spec at all is not a pass" 2 "nothing checked is not a pass"

if (( pass == 0 )); then echo "acceptance-coverage selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "acceptance-coverage selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "acceptance-coverage selftest: ok -- $pass case(s)"
