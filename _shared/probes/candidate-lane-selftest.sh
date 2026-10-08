#!/usr/bin/env bash
# candidate-lane-selftest.sh -- the verifier of verify-standard.sh's probe 19
# (`candidate-lane-segregated`) and of the `go_fail_evidence` helper.
# provenance: derived -- guards "candidate tests never run in the BLOCKING lane".
#
# THE DEFECT SHAPE. The probe compared the COUNT of files with a candidate header
# to the COUNT of files containing `go:build candidate`: two unrelated sets. One
# untagged candidate file plus two tagged files elsewhere passed. Its header regex
# also required the line to end right after `candidate`, so `candidate (TTL: 90d)`
# was never counted at all.
#
# SCENARIOS
#   a  1 untagged candidate (suffix `(TTL: 90d)`) + 2 tagged files w/o header  FAIL, names the file
#   b  `// provenance: candidate, ttl 2027-04-01`, untagged                    FAIL
#   c  every candidate file tagged, several suffix forms                       PASS
#   d  prose mentions only, untagged                                           NA
#   e  no candidate files                                                      NA
#   g  untagged candidate under .claude/worktrees, vendor, node_modules: ignored;
#      the same file in the real tree FAILS
#   a3 `// provenance: candidate, ttl: 2026-12-31` (colon), untagged          FAIL, names the file
#   c3 same header in x_candidate_test.go with //go:build candidate           PASS
#   d2 `// provenance: derived` only                                          NA
#   f  go_fail_evidence over --- FAIL / bind / build-failed samples
# PROBE_SRC=<file> points the selftest at another verify-standard.sh (used to
# show it goes RED against the old probe).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${PROBE_SRC:-}"
if [[ -z "$probe" ]]; then
  for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
fi
[[ -f "$probe" ]] || { echo "candidate-lane-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; n=0   # n = checks actually executed
bad() { echo "candidate-lane-selftest: FAIL -- $*" >&2; fails=$((fails+1)); }

blk="$tmp/block.sh"
{ echo 'row() { echo "$1 $2 $3"; }'; grep -E '^PROBE_GREP_EXCLUDES=' "$probe"; sed -n '/^# --- 19\./,/^# --- 20\./p' "$probe" | sed '$d'; } >"$blk"
[[ $(wc -l <"$blk") -gt 5 ]] || { echo "candidate-lane-selftest: FAIL -- probe 19 block not found in $probe" >&2; exit 1; }
grep -q 'candidate-lane-segregated' "$blk" || { echo "candidate-lane-selftest: FAIL -- block lacks the row" >&2; exit 1; }

run() { (cd "$1" && bash "$blk" 2>&1); }
mk() { rm -rf "$tmp/fx"; mkdir -p "$tmp/fx/pkg"; echo "$tmp/fx"; }
w() { printf '%s\n' "${@:2}" >"$1"; }

# a
d=$(mk)
w "$d/pkg/cand_test.go" '// provenance: candidate (TTL: 90d)' 'package pkg'
w "$d/pkg/t1_test.go" '//go:build candidate' 'package pkg'
w "$d/pkg/t2_test.go" '//go:build candidate' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *cand_test.go* ]] || bad "a: expected FAIL naming cand_test.go, got: $o"
# a2: same count-vacuity with the bare header (the old probe counted this one)
d=$(mk)
w "$d/pkg/bare_test.go" '// provenance: candidate' 'package pkg'
w "$d/pkg/t1_test.go" '//go:build candidate' 'package pkg'
w "$d/pkg/t2_test.go" '//go:build candidate' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *bare_test.go* ]] || bad "a2: expected FAIL naming bare_test.go, got: $o"
# b
d=$(mk); w "$d/pkg/x_test.go" '// provenance: candidate, ttl 2027-04-01' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *x_test.go* ]] || bad "b: expected FAIL, got: $o"
# c
d=$(mk)
w "$d/pkg/a_test.go" '// provenance: candidate' '//go:build candidate' 'package pkg'
w "$d/pkg/b_test.go" '//go:build integration && candidate' '// provenance: candidate (TTL: 90d), pinning: true' 'package pkg'
w "$d/pkg/c_test.go" '//go:build candidate' '// provenance: candidate, ttl 2027-04-01' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" PASS "* ]] || bad "c: expected PASS, got: $o"
# c2: a negated tag does not segregate
d=$(mk); w "$d/pkg/n_test.go" '//go:build !candidate' '// provenance: candidate' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* ]] || bad "c2: !candidate must not count as tagged, got: $o"
# d
d=$(mk)
w "$d/pkg/p_test.go" '// the provenance: candidate convention says ttl' '// provenance: candidate files carry a ttl' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" NA "* ]] || bad "d: expected NA, got: $o"
# e
d=$(mk); w "$d/pkg/q_test.go" 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" NA "* ]] || bad "e: expected NA, got: $o"

# PS-3 a3: the exact header a governed repo shipped (`, ttl: <date>` with a colon) must be seen
d=$(mk); w "$d/pkg/x_test.go" '// provenance: candidate, ttl: 2026-12-31' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *x_test.go* ]] || bad "a3: expected FAIL naming x_test.go, got: $o"
# PS-3 c3: the same header in a *_candidate_test.go carrying the build tag passes
d=$(mk); w "$d/pkg/x_candidate_test.go" '//go:build candidate' '// provenance: candidate, ttl: 2026-12-31' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" PASS "* ]] || bad "c3: expected PASS, got: $o"
# PS-3 d2: a derived header is not a candidate: never FAILs
d=$(mk); w "$d/pkg/x_test.go" '// provenance: derived' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" NA "* ]] || bad "d2: derived-only tree must be NA, got: $o"

# g: nested checkouts and vendored trees are not THIS tree
d=$(mk)
for sub in .claude/worktrees/x/pkg vendor/m node_modules/m .git/x; do
  mkdir -p "$d/$sub"; w "$d/$sub/n_test.go" '// provenance: candidate' 'package pkg'
done
w "$d/pkg/ok_test.go" 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" NA "* && "$o" != *" FAIL "* ]] || bad "g1: nested/vendored candidates must be ignored, got: $o"
w "$d/pkg/real_test.go" '// provenance: candidate' 'package pkg'
n=$((n+1)); o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *pkg/real_test.go* && "$o" != *worktrees* && "$o" != *vendor* ]] || bad "g2: real-tree file must FAIL alone, got: $o"

# f: helper
hf="$tmp/helper.sh"
sed -n '/^go_fail_evidence() {/,/^}/p' "$probe" >"$hf"
n=$((n+1))
if [[ ! -s "$hf" ]]; then bad "f: go_fail_evidence not defined in $probe"; else
  # shellcheck source=/dev/null
  source "$hf"
  s1=$'2026/01/01 log noise\n--- FAIL: TestFoo (0.00s)\n    foo_test.go:12: want 1 got 2\n--- FAIL: TestBar (0.00s)\n    bar_test.go:7: boom\nFAIL'
  n=$((n+1)); o=$(go_fail_evidence "$s1"); [[ "$o" == *"--- FAIL: TestFoo"* && "$o" == *"foo_test.go:12"* ]] || bad "f1: --- FAIL evidence: $o"
  n=$((n+1)); [[ $(grep -o -- '--- FAIL' <<<"$o" | wc -l) -le 2 ]] || bad "f1b: too many lines: $o"
  s2=$'listen tcp 127.0.0.1:8080: bind: address already in use\nFAIL\tpkg\t0.1s'
  n=$((n+1)); o=$(go_fail_evidence "$s2"); [[ "$o" == *"bind: address already in use"* ]] || bad "f2: bind: $o"
  s3=$'# pkg\n./x.go:3:1: syntax error\nFAIL\tpkg [build failed]'
  n=$((n+1)); o=$(go_fail_evidence "$s3"); [[ "$o" == *"build failed"* ]] || bad "f3: build failed: $o"
  n=$((n+1)); o=$(go_fail_evidence "ok pkg 0.1s"); [[ -z "$o" ]] || bad "f4: nothing to say should print nothing: $o"
  # f6: the CI case -- a t.Logf diagnostic precedes the t.Fatalf; the evidence must carry the FAILING line
  s6=$'=== RUN   TestX\n--- FAIL: TestX (50.44s)\n    x_test.go:406: stalled socket: 293 frames read, close code 0, err i/o timeout\n    x_test.go:409: still waiting\n    x_test.go:412: the stalled subscription ended with code 0, want 4001 or 1006\nFAIL'
  n=$((n+1)); o=$(go_fail_evidence "$s6"); [[ "$o" == *"x_test.go:412: the stalled subscription ended with code 0, want 4001 or 1006"* && "$o" == *"TestX"* ]] || bad "f6: last assertion missing: $o"
  n=$((n+1)); [[ "$o" == *"x_test.go:406"* ]] || bad "f6b: first line should ride along as context: $o"
  s7=$'--- FAIL: TestY (0.00s)\n    y_test.go:5: only one\nFAIL'
  n=$((n+1)); o=$(go_fail_evidence "$s7"); [[ "$o" == *"y_test.go:5: only one" && "$(grep -o 'y_test.go:5' <<<"$o" | wc -l | tr -d ' ')" == 1 ]] || bad "f7: single line must appear once: $o"
  s8=$'--- FAIL: TestA (0s)\n    a_test.go:1: log\n    a_test.go:2: fatal A\n--- FAIL: TestB (0s)\n    b_test.go:3: fatal B\nFAIL'
  n=$((n+1)); o=$(go_fail_evidence "$s8"); [[ "$o" == *"a_test.go:2: fatal A"* && "$o" == *"b_test.go:3: fatal B"* ]] || bad "f8: each test needs its own last assertion: $o"
  s9=$'panic: runtime error: boom\ngoroutine 1 [running]:\nFAIL\tpkg\t0.1s'
  n=$((n+1)); o=$(go_fail_evidence "$s9"); [[ "$o" == *"panic: runtime error: boom"* ]] || bad "f9: panic with no --- FAIL: $o"
  # f5: replay-corpus FAIL row must not end in a dangling ': ' when evidence is empty
  n=$((n+1)); grep -q 'rc_ev=\$(go_fail_evidence' "$probe" && grep -qF '${rc_ev:+: $rc_ev}' "$probe" || bad "f5: replay-corpus FAIL row lacks rc_ev conditional-suffix form"
  rc_ev=""; msg="3 fixtures but the harness did not run${rc_ev:+: $rc_ev}"
  n=$((n+1)); [[ "$msg" != *": " && "$msg" != *":" ]] || bad "f5b: dangling colon with empty evidence: '$msg'"
fi

if (( fails )); then echo "candidate-lane-selftest: $fails FAIL" >&2; exit 1; fi
echo "candidate-lane-selftest: ok -- $n case(s)"
