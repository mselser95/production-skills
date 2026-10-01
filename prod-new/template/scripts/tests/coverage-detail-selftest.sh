#!/usr/bin/env bash
# coverage-detail-selftest.sh -- pins what the `coverage` row says when the
# gate's `go test` did not COMPLETE (a test failed, a panic, a build error, a
# timeout) as opposed to a floor being missed.
#
# WHY. bloXroute-Labs/falcon-xyz-api-service CI run 36816769255 rendered
#     coverage  FAIL  coverage gate did not complete: ?   .../proto/udf/v1 [no test files]
# The fallback excluded `---` lines, which dropped `--- FAIL: TestX` -- the one
# line naming the failing test -- and a PASSING package's "[no test files]"
# line won. Evidence that names an innocent package is worse than none.
#
# HOW. Cases 1-7 lift coverage_fail_detail out of verify-standard.sh by its
# BEGIN/END markers (not a restatement: a selftest that reimplements the logic
# tests the reimplementation) and feed canned `go test` output. Case 8 runs the
# whole probe in a throwaway module with a failing test, so the WIRING from the
# row to the function is covered too, not only the function.
set -uo pipefail
CASES=0; fails=0
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || { echo "coverage-detail selftest: cannot reach repo root" >&2; exit 2; }
PROBE="scripts/verify-standard.sh"
[[ -r "$PROBE" ]] || PROBE="_shared/probes/verify-standard.sh"
[[ -r "$PROBE" ]] || { echo "coverage-detail selftest: cannot read $PROBE" >&2; exit 1; }

prog="$(sed -n '/^# BEGIN coverage_fail_detail$/,/^# END coverage_fail_detail$/p' "$PROBE")"
if [[ "$(wc -l <<<"$prog")" -lt 15 ]]; then
  echo "coverage-detail selftest: BEGIN/END markers no longer match in $PROBE" >&2; exit 1
fi
eval "$prog"
declare -F coverage_fail_detail >/dev/null || { echo "coverage-detail selftest: function did not load" >&2; exit 1; }

# check NAME INPUT WANT_SUBSTRING [FORBIDDEN_SUBSTRING]
check() {
  CASES=$((CASES+1))
  local got; got="$(coverage_fail_detail "$2")"
  if [[ "$got" == *"$3"* && ( -z "${4:-}" || "$got" != *"$4"* ) ]]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       got:  $got"; echo "       want: *$3*${4:+ and not *$4*}"; fails=$((fails+1)); fi
}

NOTEST=$'?   \tex.com/m/internal/proto/udf/v1\t[no test files]'
OKP=$'ok  \tex.com/m/internal/b\t0.01s'
check "failing test names the test, not the no-test-files pkg" \
"$NOTEST
$OKP
--- FAIL: TestBoom (0.00s)
    a_test.go:3: F=1 want 2
FAIL
FAIL	ex.com/m/internal/a	0.01s
FAIL" "TestBoom" "no test files"
check "failing test carries the assertion line" "--- FAIL: TestBoom (0.00s)
    a_test.go:3: F=1 want 2
FAIL" "a_test.go:3: F=1 want 2"
check "several failing tests are all named (subtests too, deduped)" "--- FAIL: TestA (0.00s)
    --- FAIL: TestA/sub (0.00s)
--- FAIL: TestB (0.00s)
--- FAIL: TestA (0.00s)" "TestA TestA/sub TestB"
check "panic is reported" "$OKP
panic: runtime error: index out of range [3] with length 2

goroutine 7 [running]:
FAIL	ex.com/m/internal/a	0.02s" "panic: runtime error: index out of range" "no test files"
check "timeout names the test still running" "panic: test timed out after 1s
running tests:
	TestSlow (1s)
goroutine 1 [running]:" "TestSlow"
check "build error reports the file:line" "# ex.com/m/internal/a
internal/a/a.go:4:9: undefined: nope
FAIL	ex.com/m/internal/a [build failed]" "internal/a/a.go:4:9: undefined: nope"
check "bare FAIL<tab>pkg line is the next fallback" "$NOTEST
$OKP
FAIL	ex.com/m/internal/z	0.1s" "ex.com/m/internal/z" "no test files"

# Case 8: the wiring, end to end, in a throwaway module.
CASES=$((CASES+1))
if ! command -v go >/dev/null 2>&1; then echo "  FAIL case 8 needs go"; fails=$((fails+1)); else
  fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/scripts" "$fx/internal/a" "$fx/internal/proto"
  printf 'module ex.com/m\ngo 1.21\n' > "$fx/go.mod"
  echo 'package proto' > "$fx/internal/proto/p.go"
  printf 'package a\nfunc F() int { return 1 }\n' > "$fx/internal/a/a.go"
  printf 'package a\nimport "testing"\nfunc TestBoom(t *testing.T) { if F() != 2 { t.Fatalf("F=%%d", F()) } }\n' > "$fx/internal/a/a_test.go"
  printf '#!/usr/bin/env bash\ngo test ./... -count=1\n' > "$fx/scripts/coverage.sh"; chmod +x "$fx/scripts/coverage.sh"
  cp "$PROBE" "$fx/scripts/verify-standard.sh"
  row="$(cd "$fx" && git init -q . 2>/dev/null; bash scripts/verify-standard.sh 2>&1 | grep -E '^coverage[[:space:]]' | head -1)"
  if [[ "$row" == *"TestBoom"* && "$row" != *"no test files"* ]]; then echo "  ok   end-to-end row names TestBoom"
  else echo "  FAIL end-to-end row"; echo "       got: $row"; fails=$((fails+1)); fi
fi

echo "coverage-detail selftest: $CASES cases, $fails failed"
[[ $fails -eq 0 ]] && { echo "ok"; exit 0; } || exit 1
