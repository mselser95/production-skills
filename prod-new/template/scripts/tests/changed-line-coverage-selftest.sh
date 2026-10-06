#!/usr/bin/env bash
# provenance: candidate (ttl: 2027-01-06); derived-from: invariant
#   a-gate-never-reports-green-over-something-it-did-not-measure
# changed-line-coverage-selftest.sh -- runs the REAL scripts/changed-line-coverage.sh
# on a throwaway git repo and shows CHANGED_LINE_EXTRA_EXCLUDES: unset and empty
# leave the output byte-identical to a run of the script without the variable
# (and, over five fixture states, to golden transcripts of the pre-change script), a valid
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

# (i-b) byte-identical to the script as it was before the variable existed.
# Baseline: golden transcripts checked in next to this selftest, in
# changed-line-coverage-golden/. They were produced by running the script at the
# commit BEFORE CHANGED_LINE_EXTRA_EXCLUDES existed (its parent, the last version
# that had no such variable) over the five fixture states below, with
# CLC_GOLDEN_WRITE_DIR=<dir> CLC_BASELINE_SCRIPT=<that script>. They are frozen data, so
# the case keeps meaning something after the new script is the one on the default
# branch, and runs in a scaffolded repo too. Each transcript is "rc=N" then the
# stdout+stderr of the run. CLC_BASELINE_SCRIPT alone also compares live.
golden="$here/changed-line-coverage-golden"
states="normal base-missing profile-missing empty-diff empty-variable"
state_run() { # state_run <state> <script-relative-path> -> transcript on stdout
  local st="$1" sc="$2" b=base cov=cover.out; local -a ev=()
  case "$st" in
    base-missing) b=nosuchbase ;;
    profile-missing) cov=nosuchprofile.out ;;
    empty-diff) b=work ;;
    empty-variable) ev=(CHANGED_LINE_EXTRA_EXCLUDES=) ;;
  esac
  local o c
  o="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=$b COVERAGE_OUT=$cov "${ev[@]+"${ev[@]}"}" bash "$sc" 2>&1)"; c=$?
  printf 'rc=%s\n%s\n' "$c" "$o"
}
if [[ -n "${CLC_GOLDEN_WRITE_DIR:-}" && -n "${CLC_BASELINE_SCRIPT:-}" ]]; then
  mkdir -p "$CLC_GOLDEN_WRITE_DIR"; cp "$CLC_BASELINE_SCRIPT" "$r/scripts/old.sh"
  for st in $states; do state_run "$st" scripts/old.sh > "$CLC_GOLDEN_WRITE_DIR/$st.golden"; done
  echo "  wrote goldens to $CLC_GOLDEN_WRITE_DIR"
fi
gbad=""; gn=0
for st in $states; do
  if [[ ! -f "$golden/$st.golden" ]]; then gbad="$gbad $st(golden missing)"; continue; fi
  gn=$((gn+1))
  now="$(state_run "$st" scripts/changed-line-coverage.sh)"
  [[ "$now" == "$(cat "$golden/$st.golden")" ]] || gbad="$gbad $st"
done
if [[ -z "$gbad" && "$gn" -eq 5 ]]; then ok "(i-b) unset path byte-identical to the pre-change script over $gn golden states"
else fail "(i-b) unset path differs from the pre-change golden transcripts:$gbad"; fi
if [[ -n "${CLC_BASELINE_SCRIPT:-}" && -f "${CLC_BASELINE_SCRIPT:-}" ]]; then
  cp "$CLC_BASELINE_SCRIPT" "$r/scripts/old.sh"
  old="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=base COVERAGE_OUT=cover.out bash scripts/old.sh 2>&1)"
  if [[ "$old" == "$base_unset" ]]; then ok "(i-c) unset output byte-identical to CLC_BASELINE_SCRIPT, live"
  else fail "(i-c) unset output differs from CLC_BASELINE_SCRIPT" "$(diff <(echo "$old") <(echo "$base_unset"))"; fi
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

# (vi) an entry that passes the prefix check but that git itself rejects is refused too
# (exit 2, git's message named), never reported as a percentage. git (2.53.0) answers
# 128 "fatal: ..." for each of these.
for badent in ":!'q" ":(exclude,foo)x" ":(exclude"; do
  runclc CHANGED_LINE_EXTRA_EXCLUDES="$badent"
  if [[ "$rc" -eq 2 && "$out" == *"git rejected the pathspec"*"fatal:"* && "$out" != *"changed-line coverage: "[0-9]*"%"* ]]; then ok "(vi) git-rejected entry '$badent' refused, rc2, git's message named"
  else fail "(vi) git-rejected entry '$badent' refused (rc=$rc)" "$out"; fi
done
runclc CHANGED_LINE_EXTRA_EXCLUDES="$EXC :!'q"
if [[ "$rc" -eq 2 && "$out" == *"git rejected the pathspec"* ]]; then ok "(vi-b) one git-rejected entry among valid ones refuses the whole value"
else fail "(vi-b) one git-rejected entry among valid ones (rc=$rc)" "$out"; fi

# (vii) a git failure on the main diff while exclusions are set is a refusal, not a
# percentage; with the variable unset the unchanged old behaviour (0/0) stays.
( cd "$r" && git checkout -q --orphan unrelated && git rm -rfq . >/dev/null 2>&1; echo x > u.txt; git add u.txt; git commit -q -m unrelated; git checkout -q work ) >/dev/null 2>&1
out="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=unrelated COVERAGE_OUT=cover.out CHANGED_LINE_EXTRA_EXCLUDES="$EXC" bash scripts/changed-line-coverage.sh 2>&1)"; rc=$?
if [[ "$rc" -eq 2 && "$out" == *"git diff failed"* && "$out" != *"changed-line coverage: "[0-9]*"%"* ]]; then ok "(vii) git failure on the diff with exclusions set is refused, rc2"
else fail "(vii) git failure on the diff with exclusions set (rc=$rc)" "$out"; fi
out="$(cd "$r" && env PATH="$tmp/bin:$PATH" CHANGED_LINE_COVERAGE_BASE=unrelated COVERAGE_OUT=cover.out bash scripts/changed-line-coverage.sh 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "changed-line coverage: 100% (0/0 lines)" ]]; then ok "(vii-b) the same failure with the variable unset keeps the old 0/0 behaviour"
else fail "(vii-b) unset keeps old behaviour (rc=$rc)" "$out"; fi

if (( bad )); then echo "changed-line-coverage selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
if (( pass == 0 )); then echo "changed-line-coverage selftest: ZERO cases ran"; exit 1; fi
echo "changed-line-coverage selftest: ok -- $pass case(s)"
