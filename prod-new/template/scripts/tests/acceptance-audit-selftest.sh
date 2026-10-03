#!/usr/bin/env bash
# acceptance-audit-selftest.sh -- drives the template Makefile's
# `acceptance-audit` target on a scratch repo with a stub `go` and a stub
# changed-line-coverage.sh, so every branch of the floor logic is shown
# firing: 0 specs, no profile, 0/0 over a real diff, below/at floor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mk="$here/../../Makefile"; [[ -f "$mk" ]] && grep -q "^acceptance-audit:" "$mk" || mk="$here/../../prod-new/template/Makefile"
grep -q '^acceptance-audit:' "$mk" || { echo "acceptance-audit selftest: Makefile with the target not found"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-audit-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

# mkrepo <name> <specs 0|1> : scratch repo, base tag on the first commit
mkrepo() {
  local r="$tmp/$1"; mkdir -p "$r/scripts" "$r/stub" "$r/acceptance"
  cp "$mk" "$r/Makefile"
  printf '#!/bin/sh\n[ "${STUB_PROFILE:-1}" = 1 ] && for a in "$@"; do case "$a" in -coverprofile=*) echo "mode: atomic" > "${a#-coverprofile=}";; esac; done\nexit 0\n' > "$r/stub/go"
  printf '#!/bin/sh\necho "changed-line coverage: $STUB_OUT lines)"\n' > "$r/scripts/changed-line-coverage.sh"
  chmod +x "$r/stub/go"
  [[ "$2" = 1 ]] && : > "$r/acceptance/x.yaml"
  echo "package a" > "$r/a.go"
  ( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m base && git tag base )
  echo "$r"
}

# run <name> <want-rc> <want-substr> <repo> [VAR=val ...]
run() {
  local name="$1" wrc="$2" want="$3" r="$4"; shift 4
  local out rc
  out="$(cd "$r" && env PATH="$r/stub:$PATH" CHANGED_LINE_COVERAGE_BASE=base "$@" make --no-print-directory acceptance-audit 2>&1)"; rc=$?
  if [[ "$rc" -eq "$wrc" && "$out" == *"$want"* ]]; then pass=$((pass+1)); echo "  ok   $name"
  else bad=$((bad+1)); echo "  FAIL $name (rc=$rc want $wrc, wanted '$want')"; echo "$out" | sed 's/^/       /'; fi
}

r="$(mkrepo nospecs 0)"
run "0 specs says so, rc0" 0 "0 specs -- nothing to audit yet" "$r" STUB_OUT="0% (0/0"

r="$(mkrepo noprofile 1)"
run "no profile written fails" 2 "wrote no coverage profile" "$r" STUB_PROFILE=0 STUB_OUT="100.0% (9/9"

r="$(mkrepo stale 1)"; mkdir -p "$r/.prod/coverage"; echo "mode: atomic" > "$r/.prod/coverage/acceptance.out"
run "stale profile from an earlier run does not satisfy it" 2 "wrote no coverage profile" "$r" STUB_PROFILE=0 STUB_OUT="100.0% (9/9"

r="$(mkrepo zero 1)"; echo "package a // changed" > "$r/a.go"
run "0/0 with non-empty diff fails" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0"

r="$(mkrepo empty 1)"
run "0/0 with empty diff passes, said" 0 "0 changed Go lines" "$r" STUB_OUT="100% (0/0"

r="$(mkrepo low 1)"; echo "package a // c" > "$r/a.go"
run "70 at floor 80 fails" 2 "70.0% of changed lines" "$r" STUB_OUT="70.0% (7/10"
run "70 at floor 60 passes" 0 ">= 60% floor" "$r" STUB_OUT="70.0% (7/10" ACCEPTANCE_AUDIT_FLOOR=60
run "79.9 fails" 2 "79.9% of changed lines" "$r" STUB_OUT="79.9% (799/1000"
run "90 passes" 0 ">= 80% floor" "$r" STUB_OUT="90.0% (9/10"

r="$(mkrepo covscript 1)"
# Override changed-line-coverage.sh to exit 3 while outputting valid format
printf '#!/bin/sh\necho "changed-line coverage: 90.0%% (9/10 lines)"\nexit 3\n' > "$r/scripts/changed-line-coverage.sh"
run "coverage script exits non-zero is graded" 2 "exited 3" "$r" STUB_OUT="90.0% (9/10"

r="$(mkrepo gofail 1)"
# Override go stub to exit 1 after writing the profile
printf '#!/bin/sh\n[ "${STUB_PROFILE:-1}" = 1 ] && for a in "$@"; do case "$a" in -coverprofile=*) echo "mode: atomic" > "${a#-coverprofile=}";; esac; done\nexit 1\n' > "$r/stub/go"
chmod +x "$r/stub/go"
run "failing acceptance run with a profile still fails" 2 "Error" "$r" STUB_OUT="90.0% (9/10"

# "N case(s)" is the shape scripts/mutation-baseline.sh reads the count from;
# "N passed, M failed" was invisible to it (found when the baseline refused).
if (( pass == 0 )); then echo "acceptance-audit selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "acceptance-audit selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "acceptance-audit selftest: ok -- $pass case(s)"
