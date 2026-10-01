#!/usr/bin/env bash
# single-suite-run-selftest.sh -- the verifier of verify-standard.sh's "the suite
# runs ONCE" block (rows tests / race / coverage / coverage-ratchet).
#
# WHY THIS EXISTS. Those four rows used to be three executions of the same Go
# suite (plain, -race, and coverage.sh's own), 48% of a real probe run. They now
# share ONE run of the repo's coverage.sh with the race detector injected by the
# PROBE (GOFLAGS gains -race), accepted only when corroborated. Every way that
# goes silently green is pinned here:
#
#   A  healthy suite, template script        -> ONE `go test`, four rows PASS
#   B  a real data race                      -> race FAIL; tests/coverage/ratchet
#                                               keep their no-detector verdicts
#   C  a failing test                        -> all four rows FAIL for real
#   D  legacy script (no marker) + a race    -> race FAIL, separate path
#   E  healthy suite + coverage FLOOR miss   -> suite rows PASS, coverage FAIL
#                                               (why the marker, not the exit
#                                               code, vouches for the suite)
#   F  -race rejected for a non-race reason  -> race FAIL carrying the cause
#   I  honest script, profile written elsewhere -> separate race run
#   J  same, with a STALE `mode: atomic` profile left in the tree -> still
#                                               separate (the rm -f guard)
#   K  legacy script (no marker), healthy    -> ONE run, four rows PASS: the
#                                               speedup needs no hook
#   L  legacy `go test ... || true` over a red suite -> tests FAIL, not PASS
#   M  script with explicit -covermode=atomic that CLEARS GOFLAGS -> must not
#                                               report race PASS from that run
#   M' clears GOFLAGS, default covermode     -> same
#   N  explicit -covermode=set (illegal with -race) -> a race-clean suite is NOT
#                                               turned into race FAIL
#   P  go called by absolute path (the probe cannot see it) -> separate path
#   Q  legacy script + floor miss -> separate path, real verdicts
#   O  race_diagnose surfaces a non-test cause line (cgo / covermode)
#
# HOW IT TESTS. It lifts the probe's REAL block out of verify-standard.sh by
# anchor (never a restatement; the END anchor must be seen too) and evals it
# inside a fixture module, with the REAL template coverage.sh and a `go` shim on
# PATH that counts `go test` invocations. If an anchor moves, the lift fails
# loudly rather than testing an empty string.
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
diag_fn="$(awk '/^race_diagnose\(\) \{/{on=1} on{print} on && /^}/{exit}' <<<"$block")"
[[ -n "$diag_fn" ]] || { echo "single-suite-run-selftest: FAIL -- could not lift race_diagnose" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shim"
cat > "$work/shim/go" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == test ]]; then
  echo "$*" >> "$GO_LOG"
  if [[ "${GO_SHIM_REJECT_RACE:-}" == 1 && ( " $* " == *" -race "* || "${GOFLAGS:-}" == *-race* ) ]]; then
    echo "go: -race requires cgo; enable cgo by setting CGO_ENABLED=1" >&2
    exit 2
  fi
fi
exec "$REAL_GO" "$@"
SH
chmod +x "$work/shim/go"

# patch_script <dir> <sed-expr> <label>: mutate the copied coverage.sh, and
# refuse to continue if the mutation changed nothing (a no-op proves nothing).
patch_script() {
  local d="$1" expr="$2" label="$3" before
  before="$(cat "$d/scripts/coverage.sh")"
  sed -i.bak "$expr" "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"
  if [[ "$before" == "$(cat "$d/scripts/coverage.sh")" ]]; then
    echo "single-suite-run-selftest: FAIL -- '$label' variant is identical to the real script; the mutation proves nothing" >&2; exit 1
  fi
}

# fixture <dir> <healthy|racy|failing> <script-variant>
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
    healthy|failing)
      local want=3; [[ "$kind" == failing ]] && want=4
      cat > "$d/p/p_test.go" <<GO
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != $want {
		t.Fatal("wrong")
	}
}
func TestCountRuns(t *testing.T) { _ = Count(1) }
GO
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
  esac
  printf 'p 1.0\n' > "$d/scripts/coverage-floors.txt"
  cp "$coverage_sh" "$d/scripts/coverage.sh"
  local gt='^go test -count=1 -coverpkg=\./\.\.\. \./\.\.\. -coverprofile="\${coverage_out}"'
  case "$script" in
    real) ;;
    legacy) patch_script "$d" '/^echo "coverage: go test completed"$/d' legacy ;;
    legacyortrue) patch_script "$d" '/^echo "coverage: go test completed"$/d' legacy
                  patch_script "$d" "s|\\(${gt}\\)\$|\\1 \\|\\| true|" ortrue ;;
    profelsewhere) patch_script "$d" 's|^coverage_out=.*|coverage_out="elsewhere.out"|' profelsewhere ;;
    # explicit atomic, but the script clears GOFLAGS: -covermode=atomic does NOT
    # prove the detector ran
    clobberatomic) patch_script "$d" "s|^go test -count=1 -coverpkg=|GOFLAGS= go test -count=1 -covermode=atomic -coverpkg=|" clobberatomic ;;
    clobber) patch_script "$d" "s|^go test -count=1 -coverpkg=|GOFLAGS= go test -count=1 -coverpkg=|" clobber ;;
    abspath) patch_script "$d" 's|^go test -count=1 -coverpkg=|"${REAL_GO}" test -count=1 -coverpkg=|' abspath ;;
    covermodeset) patch_script "$d" "s|^go test -count=1 -coverpkg=|go test -count=1 -covermode=set -coverpkg=|" covermodeset ;;
  esac
  chmod +x "$d/scripts/coverage.sh"
}

failures=0; ROWS=""; CASES=0; SCEN=0
scenario() { SCEN=$((SCEN+1)); echo "$1"; }
ok() { CASES=$((CASES+1)); echo "  ok   $1"; }
# row_line <name>: the single row of that name. DUPLICATES are an error -- a
# probe that emits a dimension twice would let the second hide behind the first.
row_line() {
  local n; n="$(awk -F'|' -v r="$1" '$1==r' <<<"$ROWS" | wc -l | tr -d ' ')"
  if [[ "$n" != 1 ]]; then echo "ROW-COUNT-$n"; return; fi
  awk -F'|' -v r="$1" '$1==r' <<<"$ROWS"
}
want_row() { # want_row <label> <name> <verdict> [evidence-substring]
  local line; line="$(row_line "$2")"
  if [[ "$line" == ROW-COUNT-* ]]; then
    echo "  FAIL $1: row '$2' was emitted ${line#ROW-COUNT-} time(s), want exactly 1" >&2; failures=$((failures+1)); return
  fi
  if [[ "${line#*|}" != "$3|"* ]]; then
    echo "  FAIL $1: row '$2' is '${line:-<absent>}', want verdict $3" >&2; failures=$((failures+1)); return
  fi
  if [[ -n "${4:-}" ]] && ! grep -qF -- "$4" <<<"$line"; then
    echo "  FAIL $1: row '$2' evidence lacks '$4' (got: $line)" >&2; failures=$((failures+1)); return
  fi
  ok "$1"
}
want_not() { # want_not <label> <name> <substring>  -- evidence must NOT contain it
  local line; line="$(row_line "$2")"
  if grep -qF -- "$3" <<<"$line"; then
    echo "  FAIL $1: row '$2' must not say '$3' (got: $line)" >&2; failures=$((failures+1)); return
  fi
  ok "$1"
}
want_runs() { # want_runs <label> <n>  -- number of `go test` invocations
  local n; n="$(wc -l < "$GO_LOG" | tr -d ' ')"
  if [[ "$n" != "$2" ]]; then
    echo "  FAIL $1: go test ran ${n}x, want $2 ($(tr '\n' ';' < "$GO_LOG"))" >&2; failures=$((failures+1)); return
  fi
  ok "$1 (go test x${n})"
}

# The eval runs in a subshell, so `row` writes to a file the parent reads back.
row() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${ROWS_FILE:-/dev/null}"; }
# run_case <kind> <script> [coverage-min] [reject-race] [stale-profile]
run_case() {
  local d="$work/$1-$2-${3:-0}-${4:-0}-${5:-0}"; fixture "$d" "$1" "$2"
  [[ "${5:-0}" == 1 ]] && printf 'mode: atomic\n' > "$d/coverage.out"
  export GO_LOG="$d/go.log" ROWS_FILE="$d/rows.txt"; : > "$GO_LOG"; : > "$ROWS_FILE"
  ( cd "$d" && export PATH="$work/shim:$PATH" COVERAGE_MIN="${3:-0}" GO_SHIM_REJECT_RACE="${4:-0}" && eval "$block" ) >"$d/probe.out" 2>&1
  ROWS=$(<"$ROWS_FILE")
  if [[ -z "$ROWS" ]]; then echo "  FAIL $1/$2: block produced no rows: $(tail -5 "$d/probe.out")" >&2; failures=$((failures+1)); fi
}

scenario "A. healthy suite, template script -> ONE execution feeds all four rows"
run_case healthy real
want_runs "A suite executed exactly once" 1
want_row "A tests PASS"            tests PASS "single -race+cover run"
want_row "A race PASS says single" race PASS "single -race+cover run"
want_row "A coverage PASS"         coverage PASS "TOTAL COVERAGE"
want_row "A ratchet PASS"          coverage-ratchet PASS "per-package floors enforced"

scenario "B. a real data race -> race FAIL; tests, coverage and ratchet keep their no-detector verdicts"
run_case racy real
want_row "B race FAIL names the race" race FAIL "DATA RACE"
want_row "B tests PASS (plain run has no detector)" tests PASS
want_row "B coverage PASS (unmodified coverage.sh)" coverage PASS "TOTAL COVERAGE"
want_row "B ratchet PASS (the ratchet exists; only the -race run died)" coverage-ratchet PASS "per-package floors enforced"
want_runs "B single + plain + separate race + unmodified coverage.sh" 4

scenario "C. a failing test -> tests, race, coverage and ratchet all FAIL for real"
run_case failing real
want_row "C tests FAIL" tests FAIL "FAIL"
want_row "C race FAIL"  race FAIL
want_row "C coverage FAIL" coverage FAIL "did not complete"
want_row "C ratchet FAIL" coverage-ratchet FAIL
want_runs "C single + plain + race + coverage.sh" 4

scenario "D. legacy script (no marker) over a real race -> race FAIL via the separate path"
run_case racy legacy
want_row "D race FAIL" race FAIL "DATA RACE"
want_not "D ...attributed to the separate run" race "single"
want_row "D tests PASS" tests PASS
want_runs "D single + plain + race + coverage.sh" 4

scenario "E. healthy suite + a coverage FLOOR miss -> suite rows PASS, coverage FAIL (the marker vouches, not the exit code)"
run_case healthy real 101
want_row "E tests PASS" tests PASS "single -race+cover run"
want_row "E race PASS"  race PASS "single -race+cover run"
want_row "E coverage FAIL names the floor" coverage FAIL "below 101"
want_row "E ratchet PASS" coverage-ratchet PASS
want_runs "E suite executed once" 1

scenario "F. -race rejected for a NON-race reason (no cgo) -> race FAIL carrying the cause; every other row real"
run_case healthy real 0 1
want_row "F race FAIL says why" race FAIL "requires cgo"
want_row "F tests PASS" tests PASS
want_row "F coverage PASS (unmodified run)" coverage PASS "TOTAL COVERAGE"
want_row "F ratchet PASS (unmodified run)" coverage-ratchet PASS "per-package floors enforced"

scenario "I. honest script, profile written elsewhere -> cannot corroborate, so a separate race run decides"
run_case healthy profelsewhere
want_row "I race PASS from its own run" race PASS "separate -race run"
want_not "I ...not attributed to the single run" race "single"
want_runs "I single + plain + race + coverage.sh" 4
run_case racy profelsewhere
want_row "I' a race is still caught" race FAIL "DATA RACE"

scenario "J. same, with a STALE mode: atomic profile in the tree -> the rm -f guard still forces the separate run"
run_case healthy profelsewhere 0 0 1
want_not "J stale profile did not vouch for the run" race "single"
want_runs "J separate path taken" 4

scenario "K. legacy script (no marker, no hook), healthy -> ONE run, four rows PASS"
run_case healthy legacy
want_runs "K suite executed exactly once" 1
want_row "K tests PASS" tests PASS "single -race+cover run"
want_row "K race PASS"  race PASS "single -race+cover run"
want_row "K coverage PASS" coverage PASS "TOTAL COVERAGE"
want_row "K ratchet PASS" coverage-ratchet PASS "per-package floors enforced"

scenario "L. legacy script that swallows go test's exit (|| true) over a red suite -> tests FAIL, never PASS"
run_case failing legacyortrue
want_row "L tests FAIL" tests FAIL
want_row "L race FAIL"  race FAIL
want_not "L no single-run PASS" tests "single"

scenario "M. explicit -covermode=atomic but GOFLAGS cleared -> NOT race PASS from that run"
run_case healthy clobberatomic
want_not "M race not certified by the single run" race "single"
want_row "M race PASS from the separate run" race PASS "separate -race run"
want_runs "M separate path taken" 4
run_case racy clobberatomic
want_row "M2 a real race is still caught" race FAIL "DATA RACE"
scenario "M'. GOFLAGS cleared, default covermode (profile not atomic)"
run_case healthy clobber
want_not "M' race not certified by the single run" race "single"
want_row "M' race PASS from the separate run" race PASS "separate -race run"

scenario "P. script that calls go by absolute path (shim never sees it) -> unverifiable, separate path"
run_case healthy abspath
want_not "P race not certified by the single run" race "single"
want_row "P race PASS from the separate run" race PASS "separate -race run"

scenario "Q. legacy script (no marker) + coverage FLOOR miss -> cannot tell a floor miss from a dead suite: separate path, real verdicts"
run_case healthy legacy 101
want_not "Q no single-run certification" race "single"
want_row "Q tests PASS" tests PASS
want_row "Q race PASS from its own run" race PASS "separate -race run"
want_row "Q coverage FAIL names the floor" coverage FAIL "below 101"

scenario "N. explicit -covermode=set (illegal with -race) on a race-clean suite -> NOT race FAIL"
run_case healthy covermodeset
want_row "N race PASS from the separate run" race PASS "separate -race run"
want_row "N tests PASS" tests PASS
want_row "N coverage PASS" coverage PASS "TOTAL COVERAGE"

scenario "O. race_diagnose surfaces a cause line for failures that are not test failures"
got="$(eval "$diag_fn"; race_diagnose $'go: -race requires cgo; enable cgo by setting CGO_ENABLED=1')"
if grep -qF "requires cgo" <<<"$got"; then ok "O cgo cause carried"; else echo "  FAIL O: cgo cause lost (got: $got)" >&2; failures=$((failures+1)); fi
got="$(eval "$diag_fn"; race_diagnose $'-covermode must be "atomic", not "set", when -race is enabled')"
if grep -qF "covermode must be" <<<"$got"; then ok "O covermode cause carried"; else echo "  FAIL O: covermode cause lost (got: $got)" >&2; failures=$((failures+1)); fi

if [[ "$failures" -ne 0 ]]; then
  echo "single-suite-run-selftest: FAIL -- ${failures} assertion(s) failed" >&2
  exit 1
fi
echo "single-suite-run-selftest: PASS -- ${CASES} case(s) over ${SCEN} scenarios against the probe's real block"
