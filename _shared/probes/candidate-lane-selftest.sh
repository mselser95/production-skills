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
fails=0
bad() { echo "candidate-lane-selftest: FAIL -- $*" >&2; fails=$((fails+1)); }

blk="$tmp/block.sh"
{ echo 'row() { echo "$1 $2 $3"; }'; sed -n '/^# --- 19\./,/^# --- 20\./p' "$probe" | sed '$d'; } >"$blk"
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
o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *cand_test.go* ]] || bad "a: expected FAIL naming cand_test.go, got: $o"
# a2: same count-vacuity with the bare header (the old probe counted this one)
d=$(mk)
w "$d/pkg/bare_test.go" '// provenance: candidate' 'package pkg'
w "$d/pkg/t1_test.go" '//go:build candidate' 'package pkg'
w "$d/pkg/t2_test.go" '//go:build candidate' 'package pkg'
o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *bare_test.go* ]] || bad "a2: expected FAIL naming bare_test.go, got: $o"
# b
d=$(mk); w "$d/pkg/x_test.go" '// provenance: candidate, ttl 2027-04-01' 'package pkg'
o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *x_test.go* ]] || bad "b: expected FAIL, got: $o"
# c
d=$(mk)
w "$d/pkg/a_test.go" '// provenance: candidate' '//go:build candidate' 'package pkg'
w "$d/pkg/b_test.go" '//go:build integration && candidate' '// provenance: candidate (TTL: 90d), pinning: true' 'package pkg'
w "$d/pkg/c_test.go" '//go:build candidate' '// provenance: candidate, ttl 2027-04-01' 'package pkg'
o=$(run "$d"); [[ "$o" == *" PASS "* ]] || bad "c: expected PASS, got: $o"
# c2: a negated tag does not segregate
d=$(mk); w "$d/pkg/n_test.go" '//go:build !candidate' '// provenance: candidate' 'package pkg'
o=$(run "$d"); [[ "$o" == *" FAIL "* ]] || bad "c2: !candidate must not count as tagged, got: $o"
# d
d=$(mk)
w "$d/pkg/p_test.go" '// the provenance: candidate convention says ttl' '// provenance: candidate files carry a ttl' 'package pkg'
o=$(run "$d"); [[ "$o" == *" NA "* ]] || bad "d: expected NA, got: $o"
# e
d=$(mk); w "$d/pkg/q_test.go" 'package pkg'
o=$(run "$d"); [[ "$o" == *" NA "* ]] || bad "e: expected NA, got: $o"

# g: nested checkouts and vendored trees are not THIS tree
d=$(mk)
for sub in .claude/worktrees/x/pkg vendor/m node_modules/m .git/x; do
  mkdir -p "$d/$sub"; w "$d/$sub/n_test.go" '// provenance: candidate' 'package pkg'
done
w "$d/pkg/ok_test.go" 'package pkg'
o=$(run "$d"); [[ "$o" == *" NA "* && "$o" != *" FAIL "* ]] || bad "g1: nested/vendored candidates must be ignored, got: $o"
w "$d/pkg/real_test.go" '// provenance: candidate' 'package pkg'
o=$(run "$d"); [[ "$o" == *" FAIL "* && "$o" == *pkg/real_test.go* && "$o" != *worktrees* && "$o" != *vendor* ]] || bad "g2: real-tree file must FAIL alone, got: $o"

# f: helper
hf="$tmp/helper.sh"
sed -n '/^go_fail_evidence() {/,/^}/p' "$probe" >"$hf"
if [[ ! -s "$hf" ]]; then bad "f: go_fail_evidence not defined in $probe"; else
  # shellcheck source=/dev/null
  source "$hf"
  s1=$'2026/01/01 log noise\n--- FAIL: TestFoo (0.00s)\n    foo_test.go:12: want 1 got 2\n--- FAIL: TestBar (0.00s)\n    bar_test.go:7: boom\nFAIL'
  o=$(go_fail_evidence "$s1"); [[ "$o" == *"--- FAIL: TestFoo"* && "$o" == *"foo_test.go:12"* ]] || bad "f1: --- FAIL evidence: $o"
  [[ $(grep -o -- '--- FAIL' <<<"$o" | wc -l) -le 2 ]] || bad "f1b: too many lines: $o"
  s2=$'listen tcp 127.0.0.1:8080: bind: address already in use\nFAIL\tpkg\t0.1s'
  o=$(go_fail_evidence "$s2"); [[ "$o" == *"bind: address already in use"* ]] || bad "f2: bind: $o"
  s3=$'# pkg\n./x.go:3:1: syntax error\nFAIL\tpkg [build failed]'
  o=$(go_fail_evidence "$s3"); [[ "$o" == *"build failed"* ]] || bad "f3: build failed: $o"
  o=$(go_fail_evidence "ok pkg 0.1s"); [[ -z "$o" ]] || bad "f4: nothing to say should print nothing: $o"
fi

if (( fails )); then echo "candidate-lane-selftest: $fails FAIL" >&2; exit 1; fi
echo "candidate-lane-selftest: ok"
