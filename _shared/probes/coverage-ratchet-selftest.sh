#!/usr/bin/env bash
# coverage-ratchet-selftest.sh -- the verifier of scripts/coverage.sh's ORDER.
#
# WHY THIS EXISTS. coverage.sh runs two checks: a global floor and a
# per-package ratchet. Until 2026-09-21 the global check ended in `exit 1`,
# and the ratchet loop sat BELOW it -- so on any repo under its global floor
# the ratchet never executed. It reported nothing, the probe row read
# "not probed", and nobody investigated, because the repo's coverage waiver
# appeared to explain the red. Measured on falcon-xyz-udf-service: a whole
# second gate dead the entire time, behind a waiver about a different number.
#
# The exit CODE was never wrong -- it was 1 either way. What was missing was
# the ratchet's VERDICT. That is precisely why it survived: nothing was red
# that should have been green, so nothing drew a second look. A gate that
# silently declines to run looks exactly like a gate that ran and was happy.
#
# That inverts the ratchet's own stated purpose: it exists BECAUSE a global
# average hides a per-package regression, so skipping it whenever the global
# number is unhealthy hides the regression in exactly the case the global
# number already failed to describe.
#
# WHAT THIS PINS. Both checks always run, both verdicts are always printed,
# and the exit status is the union. Case A is the regression itself; the
# others keep the fix from being "always print everything" without meaning.
#
# WHAT IT DOES NOT PIN. Correctness of the per-package percentages -- that is
# the awk block's job and a different test. This is about order and reporting.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The script under test, located by search rather than a single hardcoded
# path: this file is vendored into two trees (_shared/probes/ here, and
# scripts/tests/ in a scaffolded repo) and coverage.sh sits differently
# relative to each.
coverage_sh=""
for candidate in \
  "${here}/../../prod-new/template/scripts/coverage.sh" \
  "${here}/../coverage.sh" \
  "${here}/../../scripts/coverage.sh"; do
  if [[ -f "${candidate}" ]]; then coverage_sh="${candidate}"; break; fi
done
if [[ -z "${coverage_sh}" ]]; then
  echo "coverage-ratchet-selftest: FAIL -- cannot locate coverage.sh under ${here}" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "coverage-ratchet-selftest: FAIL -- go is required; a selftest that skips itself is the shape this suite refuses" >&2
  exit 1
fi

fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

# A two-package module with deliberately lopsided coverage: `good` fully
# covered, `bad` mostly not, so the global total is low AND the packages are
# separable. Both properties are needed to drive the four cases below.
mkdir -p "${fixture}/scripts" "${fixture}/good" "${fixture}/bad"
cat > "${fixture}/go.mod" <<'EOF'
module example.com/covfix

go 1.22
EOF
cat > "${fixture}/good/good.go" <<'EOF'
package good

func Add(a, b int) int { return a + b }
EOF
cat > "${fixture}/good/good_test.go" <<'EOF'
package good

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatal("bad")
	}
}
EOF
cat > "${fixture}/bad/bad.go" <<'EOF'
package bad

func Covered() int { return 1 }

func Uncovered(n int) int {
	if n > 10 {
		return 10
	}
	if n > 5 {
		return 5
	}
	if n > 2 {
		return 2
	}
	if n > 1 {
		return 1
	}
	return 0
}
EOF
cat > "${fixture}/bad/bad_test.go" <<'EOF'
package bad

import "testing"

func TestCovered(t *testing.T) {
	if Covered() != 1 {
		t.Fatal("bad")
	}
}
EOF

# The REAL script, copied rather than restated -- a selftest that reimplements
# its subject tests the reimplementation.
cp "${coverage_sh}" "${fixture}/scripts/coverage.sh"

# The regression shape, synthesised from the real script: the global check
# ending in `exit 1`. Used only to prove the assertions below can FAIL.
sed 's/^  global_failed=1$/  exit 1/' "${fixture}/scripts/coverage.sh" > "${fixture}/scripts/coverage-regressed.sh"
if ! grep -q 'exit 1' "${fixture}/scripts/coverage-regressed.sh"; then
  echo "coverage-ratchet-selftest: FAIL -- could not synthesise the regressed variant; the anchor 'global_failed=1' moved" >&2
  exit 1
fi
if diff -q "${fixture}/scripts/coverage.sh" "${fixture}/scripts/coverage-regressed.sh" >/dev/null; then
  echo "coverage-ratchet-selftest: FAIL -- the regressed variant is identical to the real script, so the mutation proves nothing" >&2
  exit 1
fi

failures=0

# run <script> <coverage_min> <floors-content> -> sets RUN_OUT / RUN_RC
run() {
  local script="$1" min="$2" floors="$3"
  printf '%s' "${floors}" > "${fixture}/scripts/coverage-floors.txt"
  RUN_OUT="$(cd "${fixture}" && COVERAGE_MIN="${min}" bash "scripts/$(basename "${script}")" 2>&1)"
  RUN_RC=$?
}

expect() { # expect <label> <needle> <present|absent>
  local label="$1" needle="$2" mode="$3"
  if [[ "${mode}" == present ]]; then
    if ! grep -qF -- "${needle}" <<<"${RUN_OUT}"; then
      echo "  FAIL ${label}: expected output to contain: ${needle}" >&2
      failures=$((failures + 1))
      return
    fi
  else
    if grep -qF -- "${needle}" <<<"${RUN_OUT}"; then
      echo "  FAIL ${label}: expected output NOT to contain: ${needle}" >&2
      failures=$((failures + 1))
      return
    fi
  fi
  echo "  ok   ${label}"
}

expect_rc() { # expect_rc <label> <code>
  if [[ "${RUN_RC}" -ne "$2" ]]; then
    echo "  FAIL $1: exit ${RUN_RC}, want $2" >&2
    failures=$((failures + 1))
    return
  fi
  echo "  ok   $1 (exit ${RUN_RC})"
}

BOTH_PASS_FLOORS=$'good 99.0\nbad 5.0\n'
BAD_BELOW_FLOORS=$'good 99.0\nbad 50.0\n'

echo "A. global floor FAILS -- the ratchet must still run and report"
run coverage.sh 85 "${BOTH_PASS_FLOORS}"
expect "A global verdict reported" "is below 85" present
expect "A ratchet still ran"      "per-package coverage ratchet: all packages at/above their floor" present
expect "A union names both"       "global floor: FAIL, per-package ratchet: ok" present
expect_rc "A exits non-zero" 1

echo "A'. the same case against the REGRESSED script -- proves A can fail"
run coverage-regressed.sh 85 "${BOTH_PASS_FLOORS}"
expect "A' ratchet verdict absent (the defect)" "per-package coverage ratchet" absent
expect_rc "A' still exits non-zero (why nobody noticed)" 1

echo "B. global floor PASSES -- a package below its floor is still caught"
run coverage.sh 0 "${BAD_BELOW_FLOORS}"
expect "B ratchet caught the package" "below its floor of 50.0%" present
expect "B union names both"           "global floor: ok, per-package ratchet: FAIL" present
expect_rc "B exits non-zero" 1

echo "C. BOTH fail -- both messages, one exit"
run coverage.sh 85 "${BAD_BELOW_FLOORS}"
expect "C global verdict reported"  "is below 85" present
expect "C ratchet verdict reported" "below its floor of 50.0%" present
expect "C union names both"         "global floor: FAIL, per-package ratchet: FAIL" present
expect_rc "C exits non-zero" 1

echo "D. no floors file -- the skip is announced, not silent"
rm -f "${fixture}/scripts/coverage-floors.txt"
RUN_OUT="$(cd "${fixture}" && COVERAGE_MIN=0 COVERAGE_FLOORS=scripts/coverage-floors.txt bash scripts/coverage.sh 2>&1)"
RUN_RC=$?
expect "D skip is stated" "per-package coverage ratchet: SKIPPED" present

# --------------------------------------------------------------------------
# E. verify-standard.sh's coverage-ratchet ROW -- the second half of the defect
#
# Fixing coverage.sh alone is not enough. The probe used to emit the
# coverage-ratchet row only inside its `if out=$(./scripts/coverage.sh)`
# SUCCESS branch, so a repo whose global floor failed got no row at all: the
# dimension counted in neither PASS, FAIL nor NA and surfaced as "not probed".
# Two independent defects, one symptom -- fixing only the script leaves the row
# silent, fixing only the row reports on a ratchet that never ran.
#
# This drives the probe's REAL decision chain, lifted by anchor rather than
# restated, against synthetic coverage.sh output. If the chain is moved back
# inside the success branch or deleted, the extraction below finds nothing and
# this fails loudly rather than silently testing an empty string.
# --------------------------------------------------------------------------
echo "E. the probe emits a coverage-ratchet row regardless of coverage.sh's exit"

probe=""
for candidate in \
  "${here}/verify-standard.sh" \
  "${here}/../../_shared/probes/verify-standard.sh" \
  "${here}/../verify-standard.sh"; do
  if [[ -f "${candidate}" ]]; then probe="${candidate}"; break; fi
done
if [[ -z "${probe}" ]]; then
  echo "  FAIL E: cannot locate verify-standard.sh to extract the row logic from" >&2
  failures=$((failures + 1))
else
  chain="$(awk '/^  # The ratchet verdict is decided ONCE/{on=1} on{print} on && /^  fi$/{exit}' "${probe}")"
  if ! grep -q 'row "coverage-ratchet"' <<<"${chain}"; then
    echo "  FAIL E: extracted no coverage-ratchet decision chain from ${probe} -- the anchor moved, so this case proves nothing" >&2
    failures=$((failures + 1))
  else
    emitted=""
    # shellcheck disable=SC2317  # called via eval'd chain below
    row() { emitted="$2 $3"; }

    check_row() { # check_row <label> <synthetic $out> <want-verdict> <want-substring>
      local label="$1" want_verdict="$3" want_sub="$4"
      # shellcheck disable=SC2034  # read by the eval'd chain below, not here
      out="$2"; emitted=""
      eval "${chain}"
      if [[ "${emitted%% *}" != "${want_verdict}" ]]; then
        echo "  FAIL ${label}: verdict '${emitted%% *}', want '${want_verdict}' (emitted: ${emitted})" >&2
        failures=$((failures + 1)); return
      fi
      if [[ -n "${want_sub}" ]] && ! grep -qF -- "${want_sub}" <<<"${emitted}"; then
        echo "  FAIL ${label}: evidence lacks '${want_sub}' (emitted: ${emitted})" >&2
        failures=$((failures + 1)); return
      fi
      echo "  ok   ${label}"
    }

    check_row "E healthy ratchet -> PASS" \
      "TOTAL COVERAGE: 90.0%
per-package coverage ratchet: all packages at/above their floor, and every measured package has one (f)" \
      PASS ""
    check_row "E package below floor -> FAIL naming it" \
      "coverage 60.0% is below 85.0%
per-package coverage ratchet: internal/app is 10.00%, below its floor of 50.0% (see f)" \
      FAIL "below its floor of 50.0%"
    check_row "E ungated package -> FAIL" \
      "coverage 60.0% is below 85.0%
per-package coverage ratchet: package 'internal/new' has measured coverage but NO floor in f" \
      FAIL "NO floor"
    check_row "E no floors file -> FAIL, not silence" \
      "TOTAL COVERAGE: 90.0%
per-package coverage ratchet: SKIPPED -- no f" \
      FAIL "nothing to check"
    check_row "E no ratchet verdict at all -> FAIL" \
      "TOTAL COVERAGE: 90.0%
coverage 60.0% is below 85.0%" \
      FAIL "no per-package ratchet in the gate"

    unset -f row check_row
  fi
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "coverage-ratchet-selftest: FAIL -- ${failures} assertion(s) failed" >&2
  exit 1
fi
echo "coverage-ratchet-selftest: PASS -- 9 case(s): 4 driving coverage.sh, 5 driving the probe's row chain, plus the regressed variant proving case A can fail"
