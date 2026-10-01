#!/usr/bin/env bash
# single-suite-run-selftest.sh -- the verifier of verify-standard.sh's "the suite
# runs ONCE" block (rows tests / race / coverage / coverage-ratchet).
#
# WHY THIS EXISTS. Those four rows used to be three executions of the same Go
# suite (plain, -race, and coverage.sh's own), 48% of a real probe run. They now
# share ONE -race+cover run, gated on a HANDSHAKE the repo's coverage.sh must
# print. Two ways that goes silently green, and this file pins both:
#
#   * the probe reports `race PASS` from a run that never had -race (a repo whose
#     coverage.sh predates the hook) -- case D;
#   * the probe reports PASS from a suite that failed, or reddens tests /
#     coverage / ratchet for a failure that was only the detector's -- B, C, F;
#   * a script prints the handshake but drops the flags -- case G;
#   * `completed` is replaced by the script's exit code, so a floor miss reads
#     as a failed suite -- case E.
#
# HOW IT TESTS. It lifts the probe's REAL block out of verify-standard.sh by
# anchor (never a restatement) and evals it inside a fixture module, with the
# REAL template coverage.sh and a `go` shim on PATH that counts `go test`
# invocations. If either anchor moves, the lift is empty and this fails loudly.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe=""; coverage_sh=""
for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do
  [[ -f "$c" ]] && { probe="$c"; break; }
done
for c in "${here}/../../prod-new/template/scripts/coverage.sh" "${here}/../coverage.sh" "${here}/../../scripts/coverage.sh"; do
  [[ -f "$c" ]] && { coverage_sh="$c"; break; }
done
[[ -n "$probe" && -n "$coverage_sh" ]] || { echo "single-suite-run-selftest: FAIL -- cannot locate probe/coverage.sh" >&2; exit 1; }
REAL_GO="$(command -v go)" || { echo "single-suite-run-selftest: FAIL -- go is required" >&2; exit 1; }
export REAL_GO

# The end anchor MUST be seen: without it awk would lift to EOF and every case
# would still run against a (larger) block -- a silently widened lift.
block="$(awk '/^# --- the suite runs ONCE/{on=1} /^# tests\/prod LOC ratio/{on=0; seen=1} on{print} END{exit seen ? 0 : 1}' "$probe")" || {
  echo "single-suite-run-selftest: FAIL -- the end anchor '# tests/prod LOC ratio' is gone from $probe; the lift would run to EOF" >&2
  exit 1
}
if ! grep -q 'race_diagnose()' <<<"$block" || ! grep -q 'row "coverage-ratchet"' <<<"$block"; then
  echo "single-suite-run-selftest: FAIL -- lifted no suite-run block from $probe; an anchor moved, so every case would test an empty string" >&2
  exit 1
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shim"
cat > "$work/shim/go" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == test ]]; then
  echo "$*" >> "$GO_LOG"
  if [[ "${GO_SHIM_REJECT_RACE:-}" == 1 && " $* " == *" -race "* ]]; then
    echo "go: -race requires cgo; enable cgo by setting CGO_ENABLED=1" >&2
    exit 2
  fi
fi
exec "$REAL_GO" "$@"
SH
chmod +x "$work/shim/go"

# fixture <dir> <healthy|racy|failing> <real|legacy>
fixture() {
  local d="$1" kind="$2" script="$3"
  mkdir -p "$d/scripts" "$d/p"
  printf 'module example.com/suitefix\n\ngo 1.22\n' > "$d/go.mod"
  cat > "$d/p/p.go" <<'GO'
package p

func Add(a, b int) int { return a + b }

func Count(n int) int {
	c := 0
	done := make(chan struct{})
	for i := 0; i < 2; i++ {
		go func() {
			for j := 0; j < n; j++ {
				c++ // unsynchronised on purpose in the racy fixture
			}
			done <- struct{}{}
		}()
	}
	<-done
	<-done
	return c
}
GO
  case "$kind" in
    healthy) cat > "$d/p/p_test.go" <<'GO'
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatal("bad")
	}
}
func TestCountRuns(t *testing.T) { _ = Count(1) }
GO
    # healthy still has to COVER Count, so Add and Count are both exercised
    # without asserting on the racy value; but Count races -> use a safe body.
    sed -i.bak 's/c++ \/\/ unsynchronised on purpose in the racy fixture/_ = c/' "$d/p/p.go"; rm -f "$d/p/p.go.bak" ;;
    racy) cat > "$d/p/p_test.go" <<'GO'
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatal("bad")
	}
}
func TestCountRaces(t *testing.T) { _ = Count(1000) }
GO
    ;;
    failing) cat > "$d/p/p_test.go" <<'GO'
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 4 {
		t.Fatal("deliberately wrong")
	}
}
func TestCountRuns(t *testing.T) { _ = Count(1) }
GO
    sed -i.bak 's/c++ \/\/ unsynchronised on purpose in the racy fixture/_ = c/' "$d/p/p.go"; rm -f "$d/p/p.go.bak" ;;
  esac
  printf 'p 1.0\n' > "$d/scripts/coverage-floors.txt"
  cp "$coverage_sh" "$d/scripts/coverage.sh"
  if [[ "$script" == flagsdropped ]]; then
    # Prints the handshake but the go test line no longer carries the flags:
    # the dishonest-script case the profile-mode corroboration exists for.
    sed -i.bak 's/go test -count=1 \${extra_flags\[@\]+"\${extra_flags\[@\]}"} -coverpkg/go test -count=1 -coverpkg/' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"
    if diff -q "$coverage_sh" "$d/scripts/coverage.sh" >/dev/null; then
      echo "single-suite-run-selftest: FAIL -- flagsdropped variant identical to the real script" >&2; exit 1
    fi
  fi
  if [[ "$script" == profelsewhere ]]; then
    # Honest handshake, but the profile lands somewhere the probe cannot read.
    sed -i.bak 's|^coverage_out=.*|coverage_out="elsewhere.out"|' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"
    if diff -q "$coverage_sh" "$d/scripts/coverage.sh" >/dev/null; then
      echo "single-suite-run-selftest: FAIL -- profelsewhere variant identical to the real script" >&2; exit 1
    fi
  fi
  if [[ "$script" == legacy ]]; then
    # A coverage.sh from before the hook: ignores COVERAGE_GO_TEST_FLAGS and
    # prints no handshake. Synthesised from the real script so it cannot drift.
    sed -i.bak 's/^extra_flags=(.*$/extra_flags=()/' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"
    sed -i.bak '/^echo "coverage: go test completed"$/d' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"
    if diff -q "$coverage_sh" "$d/scripts/coverage.sh" >/dev/null; then
      echo "single-suite-run-selftest: FAIL -- legacy variant identical to the real script; the mutation proves nothing" >&2; exit 1
    fi
  fi
  chmod +x "$d/scripts/coverage.sh"
}

failures=0; ROWS=""; CASES=0
want_row() { # want_row <label> <name> <verdict> [evidence-substring]
  local line; line="$(grep -F "$2|" <<<"$ROWS" | head -1)"
  if [[ "${line#*|}" != "$3|"* ]]; then
    echo "  FAIL $1: row '$2' is '${line:-<absent>}', want verdict $3" >&2; failures=$((failures+1)); return
  fi
  if [[ -n "${4:-}" ]] && ! grep -qF -- "$4" <<<"$line"; then
    echo "  FAIL $1: row '$2' evidence lacks '$4' (got: $line)" >&2; failures=$((failures+1)); return
  fi
  CASES=$((CASES+1)); echo "  ok   $1"
}
want_not() { # want_not <label> <name> <substring>  -- evidence must NOT contain it
  local line; line="$(grep -F "$2|" <<<"$ROWS" | head -1)"
  if grep -qF -- "$3" <<<"$line"; then
    echo "  FAIL $1: row '$2' must not say '$3' (got: $line)" >&2; failures=$((failures+1)); return
  fi
  CASES=$((CASES+1)); echo "  ok   $1"
}
want_runs() { # want_runs <label> <n>  -- number of `go test` invocations
  local n; n="$(wc -l < "$GO_LOG" | tr -d ' ')"
  if [[ "$n" != "$2" ]]; then
    echo "  FAIL $1: go test ran ${n}x, want $2 ($(tr '\n' ';' < "$GO_LOG"))" >&2; failures=$((failures+1)); return
  fi
  CASES=$((CASES+1)); echo "  ok   $1 (go test x${n})"
}

# The eval runs in a subshell, so `row` writes to a file the parent reads back.
row() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${ROWS_FILE:-/dev/null}"; }
run_case() { # run_case <kind> <script-kind> [coverage-min] [reject-race]
  local d="$work/$1-$2-${3:-0}-${4:-0}"; fixture "$d" "$1" "$2"
  export GO_LOG="$d/go.log" ROWS_FILE="$d/rows.txt"; : > "$GO_LOG"; : > "$ROWS_FILE"
  ( cd "$d" && export PATH="$work/shim:$PATH" COVERAGE_MIN="${3:-0}" GO_SHIM_REJECT_RACE="${4:-0}" && eval "$block" ) >"$d/probe.out" 2>&1
  ROWS="$(cat "$ROWS_FILE")"
  if [[ -z "$ROWS" ]]; then echo "  FAIL $1/$2: block produced no rows: $(tail -5 "$d/probe.out")" >&2; failures=$((failures+1)); fi
}

echo "A. handshake-capable coverage.sh, healthy suite -> ONE execution feeds all four rows"
run_case healthy real
want_runs "A suite executed exactly once" 1
want_row "A tests PASS"            tests PASS "single -race+cover run"
want_row "A race PASS says single" race PASS "single -race+cover run"
want_row "A coverage PASS"         coverage PASS "TOTAL COVERAGE"
want_row "A ratchet PASS"          coverage-ratchet PASS "per-package floors enforced"

echo "B. a real data race -> race FAIL; tests, coverage and ratchet keep their no-detector verdicts"
run_case racy real
want_row "B race FAIL names the race" race FAIL "DATA RACE"
want_row "B tests PASS (plain run has no detector)" tests PASS
want_row "B coverage PASS (re-derived without -race)" coverage PASS "TOTAL COVERAGE"
want_row "B ratchet PASS (the ratchet exists; only the suite run died)" coverage-ratchet PASS "per-package floors enforced"
want_runs "B single run + plain re-run + no-flags coverage.sh" 3

echo "C. a failing test -> tests, race, coverage and ratchet all FAIL for real"
run_case failing real
want_row "C tests FAIL" tests FAIL "FAIL"
want_row "C race FAIL"  race FAIL
want_row "C coverage FAIL" coverage FAIL "did not complete"
want_row "C ratchet FAIL" coverage-ratchet FAIL
want_runs "C single + plain + no-flags coverage.sh" 3

echo "D. coverage.sh WITHOUT the handshake -> separate runs, never a borrowed race PASS"
run_case healthy legacy
want_runs "D fallback ran plain + race + coverage" 3
want_row "D race PASS from the real -race run" race PASS "race detector clean"
want_not "D race evidence does not claim a single run" race "single"
run_case racy legacy
want_row "D' a race is still caught in fallback" race FAIL "DATA RACE"
want_not "D' ...and not attributed to a single run" race "single"

echo "E. healthy suite + a coverage FLOOR miss -> suite rows PASS, coverage FAIL (why 'completed' is checked, not the exit code)"
run_case healthy real 101
want_row "E tests PASS" tests PASS "single -race+cover run"
want_row "E race PASS"  race PASS "single -race+cover run"
want_row "E coverage FAIL names the floor" coverage FAIL "below 101"
want_row "E ratchet PASS" coverage-ratchet PASS
want_runs "E suite executed once" 1

echo "F. -race rejected for a NON-race reason (no cgo) -> race FAIL only; every other row real"
run_case healthy real 0 1
want_row "F race FAIL" race FAIL "single -race+cover run"
want_row "F tests PASS" tests PASS
want_row "F coverage PASS (no-flags run)" coverage PASS "TOTAL COVERAGE"
want_row "F ratchet PASS (no-flags run)" coverage-ratchet PASS "per-package floors enforced"

echo "G. script prints the handshake but DROPS the flags -> race FAIL even with no race present"
run_case healthy flagsdropped
want_row "G race FAIL, says the run was not -race" race FAIL "not 'mode: atomic'"
want_row "G tests still PASS" tests PASS
want_runs "G suite executed once" 1

echo "I. handshake honoured but the profile is unreadable -> neither a borrowed PASS nor an invented FAIL: race runs separately"
run_case healthy profelsewhere
want_row "I race PASS from its own run" race PASS "race detector clean"
want_not "I ...not attributed to the single run" race "single"
want_runs "I single + separate race run" 2
run_case racy profelsewhere
want_row "I' a race is still caught" race FAIL "DATA RACE"

echo "H. the flag list is words, never globbed"
d="$work/glob"; fixture "$d" healthy real; : > "$d/ZZglob"
hs="$(cd "$d" && PATH="$work/shim:$PATH" GO_LOG=/dev/null COVERAGE_GO_TEST_FLAGS='-race Z*' bash scripts/coverage.sh 2>&1 | grep -m1 '^coverage: go test flags:')"
if [[ "$hs" == "coverage: go test flags: -race Z*" ]]; then CASES=$((CASES+1)); echo "  ok   H flags reach go test unexpanded"
else echo "  FAIL H: handshake line was '$hs' -- the flag list was glob-expanded" >&2; failures=$((failures+1)); fi

if [[ "$failures" -ne 0 ]]; then
  echo "single-suite-run-selftest: FAIL -- ${failures} assertion(s) failed" >&2
  exit 1
fi
echo "single-suite-run-selftest: PASS -- ${CASES} case(s) over 10 scenarios (run once, race, failing test, legacy fallback x2, floor miss, non-race -race failure, dropped flags, unreadable profile, glob) against the probe's real block"
