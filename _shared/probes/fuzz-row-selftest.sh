#!/usr/bin/env bash
# fuzz-row-selftest.sh -- the verifier of verify-standard.sh's `fuzz` row.
#
# THE DEFECT SHAPE. Targets are discovered by grepping `func Fuzz*` in
# *_test.go, which ignores build tags, comments and strings, and the old row
# treated exit 0 as "ran clean". `go test -fuzz ^F$` on a target the lane never
# compiles prints "testing: warning: no fuzz tests to fuzz" and exits 0 -- a
# pass without the work. Also, two packages declaring the same target name were
# resolved to the first file only.
#
# SCENARIOS (count derived at run time):
#   A  one real target                       PASS, evidence names it as fuzzed
#   B  the same name in two packages         both fuzzed (2), not one
#   C  a build-tagged target beside a real one   PASS but the row NAMES the
#                                            tag-gated target as not fuzzed
#   D  only a build-tagged target            FAIL (nothing fuzzed in this lane)
#   E  a target present only in a comment    FAIL naming it (not listed by go)
#   F  go exits 0 without `fuzz: elapsed`    FAIL (never fuzzed)
#   G  targets under a hidden dir, a nested module, vendor/, testdata/
#                                            not this module's: PASS over the one real target
#
# It lifts the probe's real fuzz block by anchor (start AND end must be seen).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe=""
for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
[[ -n "$probe" ]] || { echo "fuzz-row-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
REAL_GO="$(command -v go)" || { echo "fuzz-row-selftest: FAIL -- go is required" >&2; exit 1; }
export REAL_GO

block="$(awk '/^fuzz_test_files\(\) \{/{on=1} on{print} on && /^else row "fuzz" FAIL "no fuzz targets"; fi$/{seen=1; exit} END{exit seen ? 0 : 1}' "$probe")" || {
  echo "fuzz-row-selftest: FAIL -- the fuzz block's start or end anchor is gone from $probe" >&2; exit 1; }
grep -q 'fuzz: elapsed' <<<"$block" || { echo "fuzz-row-selftest: FAIL -- lifted block carries no elapsed check; anchor moved" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shim"
cat > "$work/shim/go" <<'SH'
#!/usr/bin/env bash
if [[ "${GO_SHIM_NO_ELAPSED:-}" == 1 && " $* " == *" -fuzz="* ]]; then
  o=$("$REAL_GO" "$@" 2>&1); rc=$?
  grep -v 'fuzz: elapsed' <<<"$o"; exit "$rc"
fi
exec "$REAL_GO" "$@"
SH
chmod +x "$work/shim/go"

failures=0; CASES=0; SCEN=0; ROW=""
scenario() { SCEN=$((SCEN+1)); echo "$1"; }
# The eval runs in a subshell, so `row` writes to a file the parent reads back.
row() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$ROWFILE"; }
fz() { printf 'package %s\n\nimport "testing"\n\nfunc %s(f *testing.F) {\n\tf.Add(1)\n\tf.Fuzz(func(t *testing.T, n int) { _ = n })\n}\n' "$1" "$2"; }
# mk <dir> then files are added by the caller
mk() { mkdir -p "$1"; printf 'module example.com/fz\n\ngo 1.22\n' > "$1/go.mod"; }
run() { # run <dir> [no-elapsed]
  export ROWFILE="$1/row.txt"; : > "$ROWFILE"
  ( cd "$1" && export PATH="$work/shim:$PATH" GO_SHIM_NO_ELAPSED="${2:-0}" && eval "$block" ) >"$1/out.txt" 2>&1
  ROW=$(<"$ROWFILE")
}
expect() { # expect <label> <verdict> [substring]
  if [[ "${ROW#*|}" != "$2|"* ]]; then echo "  FAIL $1: row is '${ROW:-<none>}', want $2" >&2; failures=$((failures+1)); return; fi
  if [[ -n "${3:-}" ]] && ! grep -qF -- "$3" <<<"$ROW"; then echo "  FAIL $1: evidence lacks '$3' (got: $ROW)" >&2; failures=$((failures+1)); return; fi
  CASES=$((CASES+1)); echo "  ok   $1"
}

scenario "A. one real target"
d="$work/a"; mk "$d"; mkdir "$d/a"; fz a FuzzA > "$d/a/a_test.go"; run "$d"
expect "A PASS, fuzzed" PASS "1 target(s)"

scenario "B. the same target name in two packages -> both fuzzed"
d="$work/b"; mk "$d"; mkdir "$d/a" "$d/b"; fz a FuzzX > "$d/a/a_test.go"; fz b FuzzX > "$d/b/b_test.go"; run "$d"
expect "B two (package,name) pairs fuzzed" PASS "2 target(s)"

scenario "C. a build-tagged target beside a real one -> PASS, but the row names it"
d="$work/c"; mk "$d"; mkdir "$d/a" "$d/c"; fz a FuzzA > "$d/a/a_test.go"
{ printf '//go:build candidate\n\n'; fz c FuzzC; } > "$d/c/c_test.go"; run "$d"
expect "C PASS" PASS "1 target(s)"
expect "C names the tag-gated target" PASS "tag-gated, NOT fuzzed"

scenario "D. only a build-tagged target -> FAIL, nothing fuzzed"
d="$work/d"; mk "$d"; mkdir "$d/c"; { printf '//go:build candidate\n\n'; fz c FuzzC; } > "$d/c/c_test.go"; run "$d"
expect "D FAIL" FAIL "none fuzzed"

scenario "E. a target that exists only in a comment -> FAIL naming it"
d="$work/e"; mk "$d"; mkdir "$d/a"; fz a FuzzA > "$d/a/a_test.go"
printf '// func FuzzGone(f *testing.F) was deleted\n' >> "$d/a/a_test.go"; run "$d"
expect "E FAIL names FuzzGone" FAIL "FuzzGone"

scenario "G. targets in a hidden dir (agent worktree), a nested module, vendor/ and testdata/ are not this module's"
d="$work/g"; mk "$d"; mkdir -p "$d/a" "$d/.claude/worktrees/w/x" "$d/sub/y" "$d/vendor/v" "$d/a/testdata/t"
fz a FuzzA > "$d/a/a_test.go"
mk "$d/.claude/worktrees/w"; fz x FuzzHidden > "$d/.claude/worktrees/w/x/x_test.go"
mk "$d/sub"; fz y FuzzNested > "$d/sub/y/y_test.go"
fz v FuzzVendored > "$d/vendor/v/v_test.go"
fz t FuzzTestdata > "$d/a/testdata/t/t_test.go"
run "$d"
expect "G PASS over the root module's one target" PASS "1 target(s)"

scenario "F. go exits 0 but prints no 'fuzz: elapsed' -> FAIL"
d="$work/f"; mk "$d"; mkdir "$d/a"; fz a FuzzA > "$d/a/a_test.go"; run "$d" 1
expect "F FAIL" FAIL "never ran a fuzz iteration"

if [[ "$failures" -ne 0 ]]; then echo "fuzz-row-selftest: FAIL -- ${failures} assertion(s) failed" >&2; exit 1; fi
echo "fuzz-row-selftest: PASS -- ${CASES} case(s) over ${SCEN} scenarios against the probe's real fuzz block"
