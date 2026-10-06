#!/usr/bin/env bash
# provenance: candidate (ttl: 2027-01-06); derived-from: invariant
#   a-gate-never-reports-green-over-something-it-did-not-measure
# changed-line-coverage-selftest.sh -- runs the REAL scripts/changed-line-coverage.sh
# on a throwaway git repo and shows CHANGED_LINE_EXTRA_EXCLUDES: unset and empty
# leave the output byte-identical to a run of the script without the variable
# (and to the pre-change script when CLC_BASELINE_SCRIPT names it), a valid
# exclusion drops exactly the excluded files from the measured set, a malformed
# entry is refused, and exclusions that remove every file give the zero-lines output.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../changed-line-coverage.sh"
[[ -f "$script" ]] || { echo "changed-line-coverage selftest: script not found at $script"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/clc-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

ok()   { pass=$((pass+1)); echo "  ok   $1"; }
fail() { bad=$((bad+1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       /'; }

r="$tmp/repo"; mkdir -p "$r/scripts" "$r/test/harness" "$r/pkg/storetest"
cp "$script" "$r/scripts/changed-line-coverage.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
(
  cd "$r" || exit 1
  git init -q -b main .
  printf 'module example.test/m\n\ngo 1.21\n' > go.mod
  printf 'package m\n\nfunc P() int { return 1 }\n' > prod.go
  printf 'package m\n\nfunc T() int { return 1 }\n' > prod_test.go
  printf 'package harness\n\nfunc H() int { return 1 }\n' > test/harness/h.go
  printf 'package storetest\n\nfunc D() int { return 1 }\n' > pkg/storetest/double.go
  git add -A && git commit -q -m base && git tag base
  git checkout -q -b work
  printf 'package m\n\nfunc P() int {\n\ta := 2\n\treturn a\n}\n' > prod.go
  printf 'package m\n\nfunc T() int {\n\ta := 2\n\treturn a\n}\n' > prod_test.go
  printf 'package harness\n\nfunc H() int {\n\ta := 2\n\treturn a\n}\n' > test/harness/h.go
  printf 'package storetest\n\nfunc D() int {\n\ta := 2\n\treturn a\n}\n' > pkg/storetest/double.go
  git add -A && git commit -q -m change
) || { echo "changed-line-coverage selftest: fixture repo could not be built"; exit 1; }

# Profile: covers only prod.go lines 3-6 (the production change); the harness and
# the double are in the profile as blocks that were never executed.
cat > "$r/cover.out" <<'PROF'
mode: atomic
example.test/m/prod.go:3.1,6.2 1 1
example.test/m/test/harness/h.go:3.1,6.2 1 0
example.test/m/pkg/storetest/double.go:3.1,6.2 1 0
PROF
# go list -m is needed by the script: stub it so the selftest does not need a toolchain.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\n[ "$1" = list ] && echo example.test/m && exit 0\nexit 1\n' > "$tmp/bin/go"; chmod +x "$tmp/bin/go"

# run <extra env VAR=val ...> -> stdout+stderr in $out, status in $rc
runclc() {
  out="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=base COVERAGE_OUT=cover.out "$@" bash scripts/changed-line-coverage.sh 2>&1)"; rc=$?
}
EXC=':(exclude,glob)test/** :(exclude,glob)**/*test/**'

# (i) unset: every non-test line counts (production, harness and double; only the production block is executed)
runclc
base_unset="$out"
if [[ "$rc" -eq 0 && "$out" == "changed-line coverage: 33.3% (4/12 lines)" ]]; then ok "(i) unset counts production, harness and double lines"
else fail "(i) unset counts production, harness and double lines (rc=$rc)" "$out"; fi

# (i-b) byte-identical to the script as it was before the variable existed, when supplied
# Baseline: CLC_BASELINE_SCRIPT, else origin/master's copy when this runs inside the
# framework repo; a scaffolded repo has neither, and the case says it was skipped.
baseline="${CLC_BASELINE_SCRIPT:-}"
if [[ -z "$baseline" ]] && git -C "$here" show origin/master:prod-new/template/scripts/changed-line-coverage.sh > "$tmp/baseline.sh" 2>/dev/null; then baseline="$tmp/baseline.sh"; fi
if [[ -z "$baseline" || ! -f "$baseline" ]]; then echo "  n/a  (i-b) no baseline script available (not in the framework repo, CLC_BASELINE_SCRIPT unset)"
else
  cp "$baseline" "$r/scripts/old.sh"
  old="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=base COVERAGE_OUT=cover.out bash scripts/old.sh 2>&1)"
  if [[ "$old" == "$base_unset" ]]; then ok "(i-b) unset output byte-identical to the pre-change script"
  else fail "(i-b) unset output differs from the pre-change script" "$(diff <(echo "$old") <(echo "$base_unset"))"; fi
fi

# (ii) valid exclusions
runclc CHANGED_LINE_EXTRA_EXCLUDES="$EXC"
want_last="changed-line coverage: 100.0% (4/4 lines)"
if [[ "$rc" -eq 0 && "$out" == *"excluding"*"test/**"* && "$(printf '%s\n' "$out" | tail -n 1)" == "$want_last" && "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ]]; then
  ok "(ii) exclusions line printed, summary counts only production lines"
else fail "(ii) exclusions line printed, summary counts only production lines (rc=$rc)" "$out"; fi

# (iii) malformed entry
runclc CHANGED_LINE_EXTRA_EXCLUDES="test/**"
if [[ "$rc" -ne 0 && "$out" == *"'test/**'"* && "$out" != *"changed-line coverage: "[0-9]*"%"* ]]; then ok "(iii) malformed entry refused, non-zero, entry named"
else fail "(iii) malformed entry refused (rc=$rc)" "$out"; fi
runclc CHANGED_LINE_EXTRA_EXCLUDES="$EXC bad/path"
if [[ "$rc" -ne 0 && "$out" == *"'bad/path'"* ]]; then ok "(iii-b) one bad entry among valid ones refuses the whole value"
else fail "(iii-b) one bad entry among valid ones (rc=$rc)" "$out"; fi

# (iv) empty and whitespace-only behave as unset
runclc CHANGED_LINE_EXTRA_EXCLUDES=""
if [[ "$rc" -eq 0 && "$out" == "$base_unset" ]]; then ok "(iv) empty variable is byte-identical to unset"
else fail "(iv) empty variable is byte-identical to unset (rc=$rc)" "$out"; fi
runclc CHANGED_LINE_EXTRA_EXCLUDES="   "
if [[ "$rc" -eq 0 && "$out" == "$base_unset" ]]; then ok "(iv-b) whitespace-only variable is byte-identical to unset"
else fail "(iv-b) whitespace-only variable (rc=$rc)" "$out"; fi

# (v) exclusions removing every changed file -> the existing zero-lines output
runclc CHANGED_LINE_EXTRA_EXCLUDES=":(exclude,glob)**/*.go"
if [[ "$rc" -eq 0 && "$(printf '%s\n' "$out" | tail -n 1)" == "changed-line coverage: 100% (0/0 lines)" ]]; then ok "(v) all files excluded gives the zero-lines output, rc0"
else fail "(v) all files excluded (rc=$rc)" "$out"; fi

if (( bad )); then echo "changed-line-coverage selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
if (( pass == 0 )); then echo "changed-line-coverage selftest: ZERO cases ran"; exit 1; fi
echo "changed-line-coverage selftest: ok -- $pass case(s)"
