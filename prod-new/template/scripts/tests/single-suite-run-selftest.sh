#!/usr/bin/env bash
# single-suite-run-selftest.sh -- the verifier of verify-standard.sh's "the suite
# runs ONCE, and the probe runs it" block (rows tests / race / coverage /
# coverage-ratchet).
#
# THE CONTRACT UNDER TEST. The probe itself runs `go test ./... -race -count=1`
# (explicit flags, scope ./..., exit status read directly). `tests` and `race`
# come from that run ALONE, and only with positive evidence: exit 0 AND an `ok`
# line for every package that has test files. Nothing the repo's coverage.sh
# does can influence those two rows. If coverage.sh opts in (`--print-coverpkg`
# and `COVERAGE_PROFILE`) the probe adds coverage flags to the SAME run and
# hands the profile back, so the suite executes once; otherwise coverage.sh runs
# as before (two executions). Earlier designs inferred the race verdict from
# what the script chose to run and leaked a new way every round, which is why
# the scenarios below are ATTACKS on that inference, not just happy paths.
#
# SCENARIOS (the count is derived at run time, not written here):
#   A  opted-in script, healthy            one execution, four rows PASS
#   B  a real data race                    race FAIL; tests PASS (plain red-path
#                                          run); coverage + ratchet unmodified
#   C  a failing test                      tests, race, coverage, ratchet FAIL
#   D  legacy script + race                race FAIL
#   E  floor miss (opted-in and legacy)    tests/race PASS, coverage FAIL
#   F  -race rejected (no cgo)             race FAIL naming the cause
#   G  a package with tests prints no `ok` NOT certified: race FAIL
#   H  reviewer attacks on a legacy script, each over a racy suite AND a red one:
#      racefalse (-race=false after the flag), goflagsappend, pipeswallow
#      (pipe that eats go test's exit), jsonswallow, subset (./p/... only),
#      shortflag (-short -run)             none can produce tests/race PASS
#   I  an opted-in script that LIES about its coverpkg (two lines / a subset)
#                                          cannot change tests/race
#   J  legacy healthy                      two executions, rows correct
#   K  a no-test package that fails to build: ok lines alone would pass it
#   O  race_diagnose carries non-test causes (no cgo, covermode)
#   R  BROWNFIELD ONLY: the repo's own scripts/coverage.sh is exercised for the
#      modes it supports (`--print-coverpkg` live; `COVERAGE_PROFILE` on a
#      profile taken from one small package, asserting it prints the
#      "evaluating supplied profile" line and runs no go test)
#
# HOW IT TESTS. It lifts the probe's REAL block out of verify-standard.sh by
# anchor (the END anchor must be seen too) and evals it inside a fixture module
# with a `go` shim on PATH that counts `go test` invocations.
#
# WHAT IS AND IS NOT GUARANTEED. The fixtures run a built-in reference script
# (and the scaffold template's script when this file sits beside it). A
# brownfield repo's own coverage.sh generally cannot run inside a throwaway
# module, so scenarios A-J do NOT prove that script's behaviour; scenario R
# covers its two opt-in modes in the repo itself, and nothing here proves its
# floor/ratchet logic (that is coverage-ratchet-selftest.sh's job).
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
  if [[ -n "${GO_SHIM_DROP_OK:-}" ]]; then
    o=$("$REAL_GO" "$@" 2>&1); rc=$?
    grep -vE "^ok[[:space:]]+${GO_SHIM_DROP_OK}[[:space:]]" <<<"$o" || true
    exit "$rc"
  fi
fi
exec "$REAL_GO" "$@"
SH
chmod +x "$work/shim/go"

# --- the scripts under test --------------------------------------------------
# legacy_ref: a coverage.sh with no probe modes -- the pre-existing contract.
# modes_ref:  the same with --print-coverpkg / COVERAGE_PROFILE. Used as the
# opted-in script unless the scaffold template sits beside this file, in which
# case the REAL template is used.
emit_ref() { # emit_ref <modes 0|1>
  cat <<'H'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
coverage_min="${COVERAGE_MIN:-85.0}"
coverage_out="${COVERAGE_OUT:-coverage.out}"
H
  if [[ "$1" == 1 ]]; then
    cat <<'M'
if [[ "${1:-}" == "--print-coverpkg" ]]; then
  echo "./..."
  exit 0
fi
if [[ -n "${COVERAGE_PROFILE:-}" && -r "${COVERAGE_PROFILE}" ]]; then
  coverage_out="${COVERAGE_PROFILE}"
  echo "coverage: evaluating supplied profile ${coverage_out}"
else
  go test -count=1 -coverpkg=./... ./... -coverprofile="${coverage_out}"
fi
M
  else
    echo 'go test -count=1 -coverpkg=./... ./... -coverprofile="${coverage_out}"'
  fi
  cat <<'T'
total="$(go tool cover -func="${coverage_out}" | tail -n1 | grep -oE '[0-9]+\.[0-9]+%$' | tr -d '%')"
echo "TOTAL COVERAGE: ${total}% (threshold ${coverage_min}%)"
failed=0
if awk -v got="${total}" -v min="${coverage_min}" 'BEGIN { exit !(got < min) }'; then
  echo "coverage ${total}% is below ${coverage_min}%" >&2
  failed=1
fi
echo "per-package coverage ratchet: all packages at/above their floor, and every measured package has one (reference)"
exit "${failed}"
T
}
tpl_usable=0
if grep -q -- '--print-coverpkg' "$coverage_sh" && grep -q 'COVERAGE_PROFILE' "$coverage_sh" \
   && grep -q '^  go test -count=1 -coverpkg=\./\.\.\. \./\.\.\. -coverprofile=' "$coverage_sh"; then tpl_usable=1; fi

# replace_gotest <file> <full replacement line>: swap the script's go test line,
# refusing to continue if nothing changed (a no-op variant proves nothing).
replace_gotest() {
  local f="$1" repl="$2" before
  before="$(cat "$f")"
  awk -v r="$repl" '/^go test -count=1/ && !done {print r; done=1; next} {print}' "$f" > "$f.new" && mv "$f.new" "$f"
  if [[ "$before" == "$(cat "$f")" ]]; then
    echo "single-suite-run-selftest: FAIL -- variant did not change the script ($repl)" >&2; exit 1
  fi
}
GT='-count=1 -coverpkg=./... ./... -coverprofile="${coverage_out}"'
variant_line() { # variant_line <name> -> the replacement go test line
  case "$1" in
    racefalse)     echo "go test -race=false -covermode=atomic $GT" ;;
    goflagsappend) echo "GOFLAGS=\"\${GOFLAGS:-} -race=false\" go test $GT" ;;
    pipeswallow)   echo "set +o pipefail; go test $GT 2>&1 | cat > test.log; set -o pipefail" ;;
    jsonswallow)   echo "set +o pipefail; go test -json $GT | cat >/dev/null; set -o pipefail" ;;
    subset)        echo 'go test -count=1 -coverpkg=./... ./p/... -coverprofile="${coverage_out}"' ;;
    shortflag)     echo "go test -short -run '^TestAdd\$' $GT" ;;
  esac
}

# fixture <dir> <healthy|racy|failing> <script-variant>
fixture() {
  local d="$1" kind="$2" script="$3"
  mkdir -p "$d/scripts" "$d/p" "$d/q"
  printf 'module example.com/suitefix\n\ngo 1.22\n' > "$d/go.mod"
  printf 'package p\n\nfunc Add(a, b int) int { return a + b }\n' > "$d/p/p.go"
  printf 'package p\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatal("bad")\n\t}\n}\n' > "$d/p/p_test.go"
  # q carries the defect, so a script limited to ./p/... cannot see it.
  local body='c++' qtest='_ = Count(1)'
  case "$kind" in
    healthy|failing|buildbroken) body='_ = c' ;;
    racy) body='c++ // unsynchronised on purpose'; qtest='_ = Count(1000)' ;;
  esac
  cat > "$d/q/q.go" <<GO
package q

func Count(n int) int {
	c := 0
	done := make(chan struct{})
	for i := 0; i < 2; i++ {
		go func() {
			for j := 0; j < n; j++ {
				$body
			}
			done <- struct{}{}
		}()
	}
	<-done
	<-done
	return c
}
GO
  if [[ "$kind" == failing ]]; then
    printf 'package q\n\nimport "testing"\n\nfunc TestCount(t *testing.T) {\n\t_ = Count(1)\n\tt.Fatal("deliberately red")\n}\n' > "$d/q/q_test.go"
  else
    printf 'package q\n\nimport "testing"\n\nfunc TestCount(t *testing.T) {\n\t%s\n}\n' "$qtest" > "$d/q/q_test.go"
  fi
  if [[ "$kind" == buildbroken ]]; then
    # a package with NO tests that does not compile: every package that has tests
    # still prints ok, so only the exit status can say the run was red
    mkdir -p "$d/r"; printf 'package r\n\nvar X int = "not an int"\n' > "$d/r/r.go"
  fi
  printf 'p 1.0\nq 1.0\n' > "$d/scripts/coverage-floors.txt"
  case "$script" in
    modes|cplie|cpsubset)
      if (( tpl_usable )); then cp "$coverage_sh" "$d/scripts/coverage.sh"; else emit_ref 1 > "$d/scripts/coverage.sh"; fi
      [[ "$script" == cplie ]] && { sed -i.bak 's|echo "\./\.\.\."|printf "a\\nb\\n"|' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"; }
      [[ "$script" == cpsubset ]] && { sed -i.bak 's|echo "\./\.\.\."|echo "./p/..."|' "$d/scripts/coverage.sh"; rm -f "$d/scripts/coverage.sh.bak"; }
      if [[ "$script" != modes ]] && cmp -s <( [[ $tpl_usable == 1 ]] && cat "$coverage_sh" || emit_ref 1 ) "$d/scripts/coverage.sh"; then
        echo "single-suite-run-selftest: FAIL -- $script variant identical to its base" >&2; exit 1
      fi ;;
    legacy) emit_ref 0 > "$d/scripts/coverage.sh" ;;
    *) emit_ref 0 > "$d/scripts/coverage.sh"; replace_gotest "$d/scripts/coverage.sh" "$(variant_line "$script")" ;;
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
# run_case <kind> <script> [coverage-min] [reject-race] [drop-ok-pkg]
run_case() {
  local d="$work/$1-$2-${3:-0}-${4:-0}-${5:-none}"; fixture "$d" "$1" "$2"
  export GO_LOG="$d/go.log" ROWS_FILE="$d/rows.txt"; : > "$GO_LOG"; : > "$ROWS_FILE"
  ( cd "$d" && export PATH="$work/shim:$PATH" COVERAGE_MIN="${3:-0}" GO_SHIM_REJECT_RACE="${4:-0}" GO_SHIM_DROP_OK="${5:-}" && eval "$block" ) >"$d/probe.out" 2>&1
  ROWS=$(<"$ROWS_FILE")
  if [[ -z "$ROWS" ]]; then echo "  FAIL $1/$2: block produced no rows: $(tail -5 "$d/probe.out")" >&2; failures=$((failures+1)); fi
}

scenario "A. opted-in script, healthy suite -> ONE execution feeds all four rows"
run_case healthy modes
want_runs "A suite executed exactly once" 1
want_row "A tests PASS"            tests PASS "probe-owned -race run"
want_row "A race PASS"             race PASS "probe-owned -race run"
want_row "A coverage PASS"         coverage PASS "TOTAL COVERAGE"
want_row "A ratchet PASS"          coverage-ratchet PASS "per-package floors enforced"

scenario "B. a real data race -> race FAIL; tests, coverage and ratchet keep their no-detector verdicts"
run_case racy modes
want_row "B race FAIL names the race" race FAIL "DATA RACE"
want_row "B tests PASS (plain red-path run)" tests PASS
want_row "B coverage PASS (unmodified coverage.sh)" coverage PASS "TOTAL COVERAGE"
want_row "B ratchet PASS" coverage-ratchet PASS "per-package floors enforced"
want_runs "B race run + plain run + unmodified coverage.sh" 3

scenario "C. a failing test -> tests, race, coverage and ratchet all FAIL for real"
run_case failing modes
want_row "C tests FAIL" tests FAIL "FAIL"
want_row "C race FAIL"  race FAIL
want_row "C coverage FAIL" coverage FAIL "did not complete"
want_row "C ratchet FAIL" coverage-ratchet FAIL
want_runs "C race run + plain run + coverage.sh" 3

scenario "D. legacy script + a real race -> race FAIL"
run_case racy legacy
want_row "D race FAIL" race FAIL "DATA RACE"
want_row "D tests PASS" tests PASS
want_runs "D race run + plain run + coverage.sh" 3

scenario "E. coverage FLOOR miss -> suite rows PASS, coverage FAIL (opted-in and legacy)"
run_case healthy modes 101
want_row "E tests PASS" tests PASS "probe-owned"
want_row "E race PASS"  race PASS "probe-owned"
want_row "E coverage FAIL names the floor" coverage FAIL "below 101"
want_row "E ratchet PASS" coverage-ratchet PASS
want_runs "E suite executed once" 1
run_case healthy legacy 101
want_row "E' legacy tests PASS" tests PASS "probe-owned"
want_row "E' legacy coverage FAIL" coverage FAIL "below 101"
want_runs "E' race run + coverage.sh's own" 2

scenario "F. -race rejected for a NON-race reason (no cgo) -> race FAIL carrying the cause; other rows real"
run_case healthy modes 0 1
want_row "F race FAIL says why" race FAIL "requires cgo"
want_row "F tests PASS" tests PASS
want_row "F coverage PASS (unmodified run)" coverage PASS "TOTAL COVERAGE"

scenario "G. exit 0 but a package that HAS tests printed no ok line -> NOT certified"
run_case healthy modes 0 0 'example.com/suitefix/q'
want_row "G race FAIL, not certified" race FAIL "not certified"
want_not "G ...not attributed to a certified run" race "race detector clean"

scenario "H. attacks on a legacy script (the script's own go test is no longer trusted for anything)"
for v in racefalse goflagsappend pipeswallow jsonswallow subset shortflag; do
  run_case racy "$v"
  want_row "H $v: race FAIL over a racy suite" race FAIL "DATA RACE"
  want_not "H $v: no certification" race "race detector clean"
  run_case failing "$v"
  want_row "H $v: tests FAIL over a red suite" tests FAIL
  want_row "H $v: race FAIL over a red suite" race FAIL
done

scenario "I. an opted-in script that LIES about its coverpkg cannot touch tests/race"
for v in cplie cpsubset; do
  run_case racy "$v"
  want_row "I $v: race FAIL over a racy suite" race FAIL "DATA RACE"
  run_case failing "$v"
  want_row "I $v: tests FAIL over a red suite" tests FAIL
  run_case healthy "$v"
  want_row "I $v: healthy suite still PASSes" race PASS "probe-owned"
done

scenario "J. legacy script, healthy -> two executions, every row correct"
run_case healthy legacy
want_runs "J race run + coverage.sh's own" 2
want_row "J tests PASS" tests PASS "probe-owned -race run"
want_row "J race PASS"  race PASS "probe-owned -race run"
want_row "J coverage PASS" coverage PASS "TOTAL COVERAGE"
want_row "J ratchet PASS" coverage-ratchet PASS "per-package floors enforced"

scenario "K. a package WITHOUT tests that does not compile: every tested package prints ok, only the exit status is red"
run_case buildbroken modes
want_row "K race FAIL" race FAIL "probe-owned"
want_not "K ...not certified" race "race detector clean"
want_row "K tests FAIL (plain run is red too)" tests FAIL
# Without coverage flags (a legacy script) every tested package still prints ok,
# so here ONLY the exit status can say the run was red.
run_case buildbroken legacy
want_row "K' legacy: race FAIL on exit status alone" race FAIL "probe-owned"
want_not "K' legacy: ...not certified" race "race detector clean"

scenario "O. race_diagnose surfaces a cause line for failures that are not test failures"
got="$(eval "$diag_fn"; race_diagnose $'go: -race requires cgo; enable cgo by setting CGO_ENABLED=1')"
if grep -qF "requires cgo" <<<"$got"; then ok "O cgo cause carried"; else echo "  FAIL O: cgo cause lost (got: $got)" >&2; failures=$((failures+1)); fi
got="$(eval "$diag_fn"; race_diagnose $'-covermode must be "atomic", not "set", when -race is enabled')"
if grep -qF "covermode must be" <<<"$got"; then ok "O covermode cause carried"; else echo "  FAIL O: covermode cause lost (got: $got)" >&2; failures=$((failures+1)); fi

# --- R. brownfield: the REPO's own coverage.sh, in the repo --------------------
repo_root="$(cd "${here}/../.." 2>/dev/null && pwd)"
if [[ "$coverage_sh" == "${here}/../coverage.sh" && -f "${repo_root}/go.mod" ]]; then
  scenario "R. the repo's own scripts/coverage.sh, in the repo (brownfield contract)"
  repo_cov="${repo_root}/scripts/coverage.sh"
  if grep -q -- '--print-coverpkg' "$repo_cov" && grep -q 'COVERAGE_PROFILE' "$repo_cov"; then
    rcp="$(cd "$repo_root" && "$repo_cov" --print-coverpkg 2>/dev/null)"; rrc=$?
    if (( rrc == 0 )) && [[ -n "$rcp" && "$rcp" != *$'\n'* ]]; then ok "R --print-coverpkg exits 0 with one non-empty line (${#rcp} chars)"
    else echo "  FAIL R: --print-coverpkg rc=$rrc output not a single non-empty line" >&2; failures=$((failures+1)); fi
    # a profile from the smallest package that has tests, then evaluate it
    small="$(cd "$repo_root" && go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{len .GoFiles}} {{.ImportPath}}{{end}}' ./... 2>/dev/null | sed '/^$/d' | sort -n | head -1 | awk '{print $2}')"
    prof="$work/repo.cov"
    if [[ -n "$small" ]] && (cd "$repo_root" && go test -count=1 -coverpkg="$rcp" -coverprofile="$prof" "$small" >/dev/null 2>&1) && [[ -s "$prof" ]]; then
      export GO_LOG="$work/repo-go.log"; : > "$GO_LOG"
      rout="$(cd "$repo_root" && PATH="$work/shim:$PATH" COVERAGE_PROFILE="$prof" "$repo_cov" 2>&1)"
      if grep -q 'evaluating supplied profile' <<<"$rout"; then ok "R COVERAGE_PROFILE announces it evaluated the supplied profile"; else echo "  FAIL R: no 'evaluating supplied profile' line" >&2; failures=$((failures+1)); fi
      if grep -q 'TOTAL COVERAGE:' <<<"$rout"; then ok "R COVERAGE_PROFILE reaches a coverage verdict"; else echo "  FAIL R: no TOTAL COVERAGE line from the supplied profile" >&2; failures=$((failures+1)); fi
      n="$(wc -l < "$GO_LOG" | tr -d ' ')"
      if [[ "$n" == 0 ]]; then ok "R COVERAGE_PROFILE ran no go test"; else echo "  FAIL R: COVERAGE_PROFILE still ran go test ${n}x" >&2; failures=$((failures+1)); fi
    else
      echo "  FAIL R: could not produce a sample profile to evaluate (package '${small:-none}')" >&2; failures=$((failures+1))
    fi
  else
    echo "  note R: this repo's coverage.sh has no probe modes, so the probe runs it as a legacy script (two suite executions); nothing to contract-test" >&2
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  echo "single-suite-run-selftest: FAIL -- ${failures} assertion(s) failed" >&2
  exit 1
fi
echo "single-suite-run-selftest: PASS -- ${CASES} case(s) over ${SCEN} scenarios against the probe's real block"
