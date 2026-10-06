#!/usr/bin/env bash
# probe-excludes-selftest.sh -- verifier of the shared PROBE_GREP_EXCLUDES list in
# verify-standard.sh: a recursive grep that walks the repo tree must not count a
# file living in a nested checkout (.claude/worktrees/*), vendor/ or node_modules/.
# provenance: derived -- guards "a row passes or fails only on THIS tree's files".
#
# For three families (property tests, benchmarks, golden/compat files) the
# converted line is extracted from the probe by its assignment, run in a fixture
# where the ONLY qualifying file is under .claude/worktrees/x (must count 0),
# and again with the same file in the real tree (must count 1).
# PROBE_SRC=<file> points it at another verify-standard.sh (RED on 983e1ba).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${PROBE_SRC:-}"
if [[ -z "$probe" ]]; then
  for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
fi
[[ -f "$probe" ]] || { echo "probe-excludes-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; n=0   # n = checks actually executed
bad() { echo "probe-excludes-selftest: FAIL -- $*" >&2; fails=$((fails+1)); }

# count <line-prefix> <var> <fixture> -> value of <var> after running that line
count() {
  local line
  line=$(grep -m1 -F "$1" "$probe") || { bad "line '$1' not found in $probe"; echo x; return; }
  { grep -E '^PROBE_GREP_EXCLUDES=' "$probe"; echo "$line"; echo "echo \"\$$2\""; } >"$tmp/s.sh"
  (cd "$3" && bash "$tmp/s.sh" 2>/dev/null)
}
fx() { rm -rf "$tmp/fx"; mkdir -p "$tmp/fx/pkg" "$tmp/fx/.claude/worktrees/x/pkg" "$tmp/fx/vendor/v"; echo "$tmp/fx"; }

check() { # check <name> <line-prefix> <var> <content-line> <filename> <countkind>
  local d o
  d=$(fx); printf '%s\n%s\n' 'package pkg' "$4" >"$d/.claude/worktrees/x/pkg/$5"
  cp "$d/.claude/worktrees/x/pkg/$5" "$d/vendor/v/$5"
  o=$(count "$2" "$3" "$d")
  n=$((n+1)); [[ -z "$(echo "$o" | tr -d '[:space:]')" || "$o" == 0 ]] || bad "$1: nested-only file was counted (got '$o')"
  d=$(fx); printf '%s\n%s\n' 'package pkg' "$4" >"$d/pkg/$5"
  o=$(count "$2" "$3" "$d")
  n=$((n+1)); [[ -n "$(echo "$o" | tr -d '[:space:]')" && "$o" != 0 ]] || bad "$1: real-tree file was NOT counted (got '$o')"
}

check property 'prop_n=$(grep -rho' prop_n 'func TestPropertyFoo(t *testing.T) {}' p_test.go
check benchmark 'bench_declared=$(grep -rh' bench_declared 'func BenchmarkFoo(b *testing.B) {}' b_test.go
check compat 'compat_files=$(grep -rl' compat_files '// uses x.golden' c_test.go

if (( fails )); then echo "probe-excludes-selftest: FAIL ($fails)" >&2; exit 1; fi
echo "probe-excludes-selftest: OK -- $n case(s)"
