#!/usr/bin/env bash
# provenance-headers-selftest.sh -- verifier of verify-standard.sh's
# `provenance-headers` row (PS-4).
# provenance: derived -- guards "every ADDED test func carries its own provenance header".
#
# THE DEFECT SHAPE. The row compared the COUNT of added `provenance:` lines with the
# COUNT of added funcs. A rename (header untouched, so no `+provenance:` in the diff)
# went red, and a diff where one func had a header and its neighbour none could pass
# whenever the counts happened to coincide. The row now PAIRS each added func with the
# comment block above it in the HEAD post-image.
#
# SCENARIOS
#   a  renamed func, header line unchanged                       PASS
#   b  new func, no header                                       FAIL naming it
#   c  new func, header 3 lines above (verifies/author between)  PASS
#   d  two new funcs, one header                                 FAIL naming the unheaded one
#   e  no test func added                                        NA
#   f  two headers above one func, none above its neighbour      FAIL naming the naked one
#   g  header 12 comment lines above PASS; 13 lines above        FAIL
#   h  test file in a directory whose name has a space           PASS when headed
#   j  one file, TWO hunks, both funcs headed                    PASS
#   j2 same, the LATER func unheaded                             FAIL naming a_test.go:<its real line>
#   i  `func TestMain` without a header                          NA (harness entry, not a test)
# PROBE_SRC=<file> points the selftest at another verify-standard.sh (used to show
# it goes RED against the old counting probe).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${PROBE_SRC:-}"
if [[ -z "$probe" ]]; then
  for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
fi
[[ -f "$probe" ]] || { echo "provenance-headers-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; n=0
bad() { echo "provenance-headers-selftest: FAIL -- $*" >&2; fails=$((fails+1)); }

blk="$tmp/block.sh"
{ echo 'row() { echo "$1 $2 $3"; }'
  sed -n '/^if base="\$prov_base"; /,/^# --- 21\./p' "$probe" | sed '$d'; } >"$blk"
[[ $(wc -l <"$blk") -gt 10 ]] || { echo "provenance-headers-selftest: FAIL -- row block not found in $probe" >&2; exit 1; }
grep -q 'provenance-headers' "$blk" || { echo "provenance-headers-selftest: FAIL -- block lacks the row" >&2; exit 1; }

# run <base-content> <head-content> -> the row line
run() {
  local d="$tmp/fx"; rm -rf "$d"; mkdir -p "$d"
  ( cd "$d" || exit 2
    git init -q . && git config user.email t@t && git config user.name t
    printf '%s\n' "package p" >seed_test.go
    tf="${3:-x_test.go}"; mkdir -p "$(dirname "$tf")"
    printf '%s\n' "$1" >"$tf"
    git add . && git commit -q -m base
    printf '%s\n' "$2" >"$tf"
    git add . 
    git commit -qam head
    export prov_base; prov_base=$(git rev-parse HEAD~1)
    bash "$blk" 2>&1 )
}

H='// provenance: derived'
# a: rename, header unchanged
n=$((n+1)); o=$(run "package p
$H
func TestOld(t *testing.T) {}" "package p
$H
func TestNew(t *testing.T) {}")
[[ "$o" == *" PASS "* ]] || bad "a: renamed func with unchanged header must PASS, got: $o"
# b: no header
n=$((n+1)); o=$(run "package p" "package p
func TestBare(t *testing.T) {}")
[[ "$o" == *" FAIL "* && "$o" == *TestBare* ]] || bad "b: expected FAIL naming TestBare, got: $o"
# c: header with verifies/author between
n=$((n+1)); o=$(run "package p" "package p
$H
// verifies: INV-1
//
// author: x
func TestFar(t *testing.T) {}")
[[ "$o" == *" PASS "* ]] || bad "c: header 3 lines above must PASS, got: $o"
# d: two funcs, one header
n=$((n+1)); o=$(run "package p" "package p
$H
func TestHeaded(t *testing.T) {}

func TestNaked(t *testing.T) {}")
[[ "$o" == *" FAIL "* && "$o" == *TestNaked* && "$o" != *TestHeaded* ]] || bad "d: expected FAIL naming only TestNaked, got: $o"
# f: two headers above one func, none above the neighbour (counts coincide: 2 vs 2)
n=$((n+1)); o=$(run "package p" "package p
$H
$H
func TestTwice(t *testing.T) {}

func TestNaked(t *testing.T) {}")
[[ "$o" == *" FAIL "* && "$o" == *TestNaked* && "$o" != *TestTwice* ]] || bad "f: expected FAIL naming only TestNaked, got: $o"
# g: the 12-line window. header is the Nth comment line above the func.
fill() { local k=$1 i; for ((i=0;i<k;i++)); do printf '// note\n'; done; }
n=$((n+1)); o=$(run "package p" "package p
$H
$(fill 11)
func TestEdge12(t *testing.T) {}")
[[ "$o" == *" PASS "* ]] || bad "g12: header 12 lines above must PASS, got: $o"
n=$((n+1)); o=$(run "package p" "package p
$H
$(fill 12)
func TestEdge13(t *testing.T) {}")
[[ "$o" == *" FAIL "* && "$o" == *TestEdge13* ]] || bad "g13: header 13 lines above must FAIL, got: $o"
# h: a path with a space
n=$((n+1)); o=$(run "package p" "package p
$H
func TestSpace(t *testing.T) {}" "my dir/x_test.go")
[[ "$o" == *" PASS "* ]] || bad "h: headed func under a directory with a space must PASS, got: $o"
# j: two hunks in one file. The middle is unrelated code so the added funcs land in
# separate hunks; the line number of the second must come from ITS hunk header.
MID="$(for i in $(seq 1 15); do printf 'var v%s = %s\n' "$i" "$i"; done)"
JBASE="package p
$MID"
n=$((n+1)); o=$(run "$JBASE" "package p
$H
func TestTop(t *testing.T) {}
$MID
$H
func TestBottom(t *testing.T) {}" "a_test.go")
[[ "$o" == *" PASS "* ]] || bad "j: two headed funcs in separate hunks must PASS, got: $o"
JHEAD="package p
$H
func TestTop(t *testing.T) {}
$MID
func TestBottom(t *testing.T) {}"
want=$(printf '%s\n' "$JHEAD" | grep -n 'func TestBottom' | cut -d: -f1)
n=$((n+1)); o=$(run "$JBASE" "$JHEAD" "a_test.go")
[[ "$o" == *" FAIL "* && "$o" == *"a_test.go:$want TestBottom"* && "$o" != *TestTop* ]] || bad "j2: expected FAIL naming a_test.go:$want TestBottom, got: $o"
# i: TestMain is the harness entry, not a test
n=$((n+1)); o=$(run "package p" "package p
func TestMain(m *testing.M) {}")
[[ "$o" == *" NA "* ]] || bad "i: TestMain without a header must be NA, got: $o"

# e: nothing added
n=$((n+1)); o=$(run "package p" "package p
var x = 1")
[[ "$o" == *" NA "* ]] || bad "e: expected NA, got: $o"

[[ $n -ge 5 ]] || { echo "provenance-headers-selftest: FAIL -- only $n checks ran" >&2; exit 1; }
if (( fails )); then echo "provenance-headers-selftest: $fails FAIL" >&2; exit 1; fi
echo "provenance-headers-selftest: ok -- $n case(s)"
