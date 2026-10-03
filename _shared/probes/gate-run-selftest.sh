#!/usr/bin/env bash
# gate-run-selftest.sh — prove gate-run.sh truncates, keeps what matters, and
# propagates the exit code.
#
# Cases: short output whole; long passing output -> header + tail only with
# stdout < 1/4 of the log (the non-vacuity assertion: remove the truncation and
# this goes RED); long failing output keeps the FAIL line and exit code 3;
# failure lines capped at 40 and deduplicated; --tail honoured; bad flags -> exit 2;
# no trailing newline handled; unwritable TMPDIR -> exit 2 without running CMD;
# same label twice -> two distinct logs.
#
# Usage: bash _shared/probes/gate-run-selftest.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/gate-run.sh"
# vendored layout: scripts/tests/<selftest> beside scripts/<probe>
[[ -f "$probe" ]] || probe="$here/../gate-run.sh"
[[ -f "$probe" ]] || { echo "gate-run selftest: probe not found beside or above $here"; exit 1; }
CASES=0 FAILS=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-run-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"

ok() { CASES=$((CASES + 1)); }
bad() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $1" >&2; }

LONG='i=0; while [ $i -lt 2000 ]; do echo "line $i padding padding padding"; i=$((i+1)); done'
firstline() { printf '%s\n' "$1" | head -n 1; }
section() { printf '%s\n' "$1" | sed -n '/^== failures/,/^== tail/p'; }
logof() { local h; h="$(firstline "$1")"; h="${h#*log=}"; printf '%s' "${h% lines=*}"; }

# 1. short output printed whole
out="$(bash "$probe" --label short -- echo hello)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *$'\nhello' ]] && [[ "$out" != *'== tail'* ]]; then ok; else bad "short output not printed whole (rc=$rc)"; fi

# 2. long passing output: header + tail only, stdout < 1/4 of the log
out="$(bash "$probe" --label longpass -- bash -c "$LONG")"; rc=$?
logpath="$(logof "$out")"
logbytes="$(wc -c < "$logpath" | tr -d ' ')"
outbytes="$(printf '%s\n' "$out" | wc -c | tr -d ' ')"
hdr="$(firstline "$out")"
if [ "$rc" = 0 ] && [[ "$hdr" == "gate-run: longpass exit=0 log="*" lines=2000" ]] \
   && [[ "$out" == *$'\nline 1999 '* ]] && [ $((outbytes * 4)) -lt "$logbytes" ]; then ok
else bad "long passing output not truncated (rc=$rc out=$outbytes log=$logbytes)"; fi

# 3. long failing output: FAIL line kept in failures, exit code propagated
out="$(bash "$probe" --label longfail -- bash -c "$LONG; echo '--- FAIL: TestNeedle'; exit 3")"; rc=$?
fsec="$(section "$out")"
hdr="$(firstline "$out")"
if [ "$rc" = 3 ] && [[ "$hdr" == *' exit=3 '* ]] && [[ "$fsec" == *'--- FAIL: TestNeedle'* ]]; then ok
else bad "failure not surfaced / exit not propagated (rc=$rc)"; fi

# 4. failure pattern lines capped at 40
out="$(bash "$probe" --label cap -- bash -c 'i=0; while [ $i -lt 200 ]; do echo "FAIL distinct $i"; i=$((i+1)); done; exit 1')"
n="$(section "$out" | grep -c '^FAIL distinct')"
if [ "$n" = 40 ]; then ok; else bad "failure lines not capped at 40 (got $n)"; fi

# 5. --tail 5 honoured
out="$(bash "$probe" --tail 5 --label tail5 -- bash -c "$LONG")"
n="$(printf '%s\n' "$out" | sed -n '/^== tail/,$p' | grep -c '^line ')"
if [ "$n" = 5 ]; then ok; else bad "--tail 5 printed $n lines"; fi

# 6. missing -- -> exit 2 with usage
err="$(bash "$probe" echo hi 2>&1 >/dev/null)"; rc=$?
if [ "$rc" = 2 ] && [[ "$err" == usage:* ]]; then ok; else bad "missing -- gave rc=$rc"; fi

# 7. dedup: the same failure line 5x appears exactly once in the failures section
out="$(bash "$probe" --label dedup -- bash -c "$LONG; for k in 1 2 3 4 5; do echo 'FAIL repeated'; done; exit 1")"
n="$(section "$out" | grep -c '^FAIL repeated$')"
if [ "$n" = 1 ]; then ok; else bad "duplicate failure line printed $n times"; fi

# 8. no trailing newline: lines= counts the last line, output does not run on
out="$(bash "$probe" --label nonl -- printf 'a\nb')"; rc=$?
hdr="$(firstline "$out")"
if [ "$rc" = 0 ] && [[ "$hdr" == *' lines=2' ]] && [[ "$out" == *$'\na\nb' ]]; then ok; else bad "no-trailing-newline handling (hdr=$hdr)"; fi
raw="$(bash "$probe" --label nonl2 -- printf 'x'; echo END)"
if [[ "$raw" == *$'\nx\nEND' ]]; then ok; else bad "whole output ran into next text"; fi

# 9. --tail must be a positive integer
for bad_tail in '' 0 abc -3; do
  bash "$probe" --tail "$bad_tail" -- echo hi >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok; else bad "--tail '$bad_tail' gave rc=$rc, want 2"; fi
done

# 10. unusable TMPDIR: ERROR, exit 2, and CMD is NOT run
marker="$tmp/ran"
out="$(TMPDIR="$tmp/does-not-exist" bash "$probe" --label x -- touch "$marker")"; rc=$?
if [ "$rc" = 2 ] && [[ "$out" == 'gate-run: ERROR cannot create log in '* ]] && [ ! -e "$marker" ]; then ok; else bad "bad TMPDIR: rc=$rc ran=$([ -e "$marker" ] && echo yes || echo no)"; fi

# 11. same label twice -> distinct logs, neither clobbered
o1="$(bash "$probe" --label same -- echo one)"; o2="$(bash "$probe" --label same -- echo two)"
l1="$(logof "$o1")"; l2="$(logof "$o2")"
if [ "$l1" != "$l2" ] && [ "$(cat "$l1")" = one ] && [ "$(cat "$l2")" = two ]; then ok; else bad "same label clobbered ($l1 $l2)"; fi

# 12. label is sanitised: spaces and slashes become _
out="$(bash "$probe" --label 'a b/c' -- echo hi)"
hdr="$(firstline "$out")"
if [[ "$hdr" == 'gate-run: a_b_c exit=0 log='* ]]; then ok; else bad "label not sanitised ($hdr)"; fi

# 13. boundary: output of exactly --max-bytes is NOT whole (spec: under)
out="$(bash "$probe" --max-bytes 6 --label bound -- printf 'abcde\n')"
if [[ "$out" == *'== tail'* ]]; then ok; else bad "output == max-bytes printed whole"; fi

if [ "$FAILS" -ne 0 ]; then echo "gate-run selftest: $FAILS of $CASES case(s) FAILED" >&2; exit 1; fi
echo "gate-run selftest: ok -- $CASES case(s)"
