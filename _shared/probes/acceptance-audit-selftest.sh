#!/usr/bin/env bash
# acceptance-audit-selftest.sh -- drives the template Makefile's
# `acceptance-audit` target on a scratch repo with a stub `go` and a stub
# changed-line-coverage.sh, so every branch of the floor logic is shown
# firing: 0 specs, no profile, 0/0 over a real diff, below/at floor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mk="$here/../../Makefile"; own=1
if ! { [[ -f "$mk" ]] && grep -q "^acceptance-audit:" "$mk"; }; then mk="$here/../../prod-new/template/Makefile"; own=0; fi
grep -q '^acceptance-audit:' "$mk" || { echo "acceptance-audit selftest: Makefile with the target not found"; exit 1; }
root="$(cd "$(dirname "$mk")" && pwd)"
# A repo may carry a customised changed-line-coverage.sh (different CLI/output) with an
# acceptance-audit recipe adapted to it; template-format stubs cannot drive that.
# Inside this repo (own=0) the root IS the template, so there is nothing to compare.
if [[ "$own" = 1 ]]; then
  clc="$root/scripts/changed-line-coverage.sh"
  prov="$root/.prod/template-provenance.yaml"
  stamped=""
  # (a) the repo's own stamp: template_sha256 is the template's copy at stamp time, so
  # CI (where the template is not installed) can still tell stock from customised.
  if [[ -f "$prov" ]]; then
    stamped="$(awk '/^[[:space:]]*-[[:space:]]*path:/ { sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, ""); cur=$0; next }
      cur == "scripts/changed-line-coverage.sh" && /template_sha256:/ { sub(/.*template_sha256:[[:space:]]*/, ""); print $1; exit }' "$prov")"
  fi
  if [[ -n "$stamped" ]]; then
    if [[ "$(shasum -a 256 "$clc" | awk '{print $1}')" != "$stamped" ]]; then
      echo "acceptance-audit selftest: n/a -- scripts/changed-line-coverage.sh differs from the template copy recorded per .prod/template-provenance.yaml (repo-customised); the recipe is exercised by make acceptance-audit itself, 0 case(s) run"
      exit 0
    fi
  else
    # (b) no stamp entry: compare against the installed template, if any.
    tdir="${TEMPLATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/prod-new/template}"
    tcl="$tdir/scripts/changed-line-coverage.sh"
    if [[ ! -f "$tcl" ]]; then
      # (c) unknowable: an absent subject is a failure, never a green (0 cases run over nothing).
      echo "acceptance-audit selftest: n/a -- template dir not resolvable ($tdir) and no .prod/template-provenance.yaml entry; cannot tell whether scripts/changed-line-coverage.sh is repo-customised; the recipe is exercised by make acceptance-audit itself, 0 case(s) run"
      exit 2
    fi
    # Genuine n/a: the repo customised the script, so template-format stubs cannot drive it.
    if ! cmp -s "$clc" "$tcl"; then
      n="$(diff "$clc" "$tcl" 2>/dev/null | wc -l | tr -d ' ')"
      echo "acceptance-audit selftest: n/a -- scripts/changed-line-coverage.sh is repo-customised ($n diff lines); the recipe is exercised by make acceptance-audit itself, 0 case(s) run"
      exit 0
    fi
  fi
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-audit-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0 skipped=0

# src: the root mkrepo copies scripts/ and .github/ci-tools.txt from. It carries a
# contract wrapper and a ci-tools file so those two copies are observable by cases.
src="$tmp/src"; mkdir -p "$src/scripts" "$src/.github"
[[ -d "$root/scripts" ]] && cp -R "$root/scripts/." "$src/scripts/"
printf '#!/bin/sh\necho contract-wrapped >&2\nexec "$@"\n' > "$src/scripts/with-contract.sh"; chmod +x "$src/scripts/with-contract.sh"
printf 'fixture-tool\nsecond\n' > "$src/.github/ci-tools.txt"

# mkrepo <name> <specs 0|1> : scratch repo, base tag on the first commit
mkrepo() {
  local r="$tmp/$1"; mkdir -p "$r/scripts" "$r/stub" "$r/acceptance"
  cp "$mk" "$r/Makefile"
  cp -R "$src/scripts/." "$r/scripts/"
  rm -rf "$r/scripts/tests"
  mkdir -p "$r/.github"; cp "$src/.github/ci-tools.txt" "$r/.github/"
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

r="$(mkrepo wrapped 1)"; echo "package a // c" > "$r/a.go"
# Fixture-private variable (no repo defines it), and match the recipe line by its
# distinctive tail with any prefix (go / $(GO) go / $(GO)) so a repo's own wrapper
# variable can neither be overridden nor abort the suite.
{ echo 'AUDIT_SELFTEST_WRAPPER := scripts/with-contract.sh'; sed -E $'s#^\t  (\\$\\(GO\\) go|\\$\\(GO\\)|go) test -count=1 -tags=integration#\t  $(AUDIT_SELFTEST_WRAPPER) go test -count=1 -tags=integration#' "$r/Makefile"; } > "$r/Makefile.new"; mv "$r/Makefile.new" "$r/Makefile"
if ! grep -q 'AUDIT_SELFTEST_WRAPPER) go test' "$r/Makefile"; then
  skipped=$((skipped+1)); echo "  n/a  recipe through a scripts/ wrapper -- recipe line not in a recognised form; skipped"
else
run "recipe through a scripts/ wrapper (scripts copied) passes" 0 "contract-wrapped" "$r" STUB_OUT="90.0% (9/10"
fi

r="$(mkrepo citools 1)"; echo "package a // c" > "$r/a.go"
{ echo 'CI_TOOL := $(shell awk '"'"'NR==1'"'"' .github/ci-tools.txt)'; sed 's|mkdir -p "$(ACCEPTANCE_AUDIT_COVER_DIR)"; |&echo "ci-tool=$(CI_TOOL)"; |' "$r/Makefile"; } > "$r/Makefile.new"; mv "$r/Makefile.new" "$r/Makefile"
if ! grep -q 'ci-tool=' "$r/Makefile"; then
  skipped=$((skipped+1)); echo "  n/a  recipe reading .github/ci-tools.txt -- recipe line not in a recognised form; skipped"
else
  run "recipe reading .github/ci-tools.txt (copied) passes" 0 "ci-tool=fixture-tool" "$r" STUB_OUT="90.0% (9/10"
fi

# n/a branches: only drivable from a repo-shaped root (own=1); in-repo (own=0) the
# root is the template, so build a scratch repo from it. Skipped where own=1 already.
nested() { # nested <name> <want-rc> <want-substr> <TEMPLATE_DIR>
  local name="$1" wrc="$2" want="$3" td="$4" out rc pid wd
  out="$tmp/nested.out"
  ( cd "$tmp/nrepo" && TEMPLATE_DIR="$td" HOME="$tmp/nhome" bash scripts/tests/acceptance-audit-selftest.sh > "$out" 2>&1 ) & pid=$!
  ( sleep 60; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?; pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [[ "$rc" -eq "$wrc" && "$(cat "$out")" == *"$want"* ]]; then pass=$((pass+1)); echo "  ok   $name"
  else bad=$((bad+1)); echo "  FAIL $name (rc=$rc want $wrc, wanted '$want')"; sed 's/^/       /' "$out"; fi
}
if [[ "$own" = 0 ]]; then
  mkdir -p "$tmp/nrepo"; cp -R "$root/." "$tmp/nrepo/"; mkdir -p "$tmp/nrepo/scripts/tests"
  cp "${BASH_SOURCE[0]}" "$tmp/nrepo/scripts/tests/acceptance-audit-selftest.sh"
  mkdir -p "$tmp/nhome" "$tmp/nrepo/.prod"
  nclc="$tmp/nrepo/scripts/changed-line-coverage.sh"
  # (i) stock per the stamp, template unresolvable: the cases run (13), no TEMPLATE_DIR needed.
  printf 'files:\n  - path: scripts/changed-line-coverage.sh\n    sha256: x\n    template_sha256: %s\n' \
    "$(shasum -a 256 "$nclc" | awk '{print $1}')" > "$tmp/nrepo/.prod/template-provenance.yaml"
  nested "stamped-stock changed-line-coverage.sh runs the cases without a template" 0 "ok -- 13 case(s)" "/nonexistent"
  # (ii) one comment line added: differs from the stamped template copy -> n/a, rc0.
  echo "# customised" >> "$nclc"
  nested "stamped-customised changed-line-coverage.sh is n/a per provenance, rc0" 0 "per .prod/template-provenance.yaml" "/nonexistent"
  # (iii) stamp present but no entry for the script, no template: unknowable -> rc2.
  printf 'files:\n  - path: scripts/other.sh\n    sha256: x\n    template_sha256: y\n' > "$tmp/nrepo/.prod/template-provenance.yaml"
  nested "no provenance entry and no template is rc2" 2 "no .prod/template-provenance.yaml entry" "/nonexistent"
  rm -rf "$tmp/nrepo/.prod"
  nested "customised changed-line-coverage.sh is n/a, rc0" 0 "repo-customised" "$root"
  nested "unresolvable template dir is rc2, not a green" 2 "template dir not resolvable" "/nonexistent"
fi

# "N case(s)" is the shape scripts/mutation-baseline.sh reads the count from;
# "N passed, M failed" was invisible to it (found when the baseline refused).
if (( pass == 0 && skipped > 0 )); then echo "acceptance-audit selftest: nothing was measured -- 0 case(s) run, $skipped skipped"; exit 2; fi
if (( pass == 0 )); then echo "acceptance-audit selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "acceptance-audit selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "acceptance-audit selftest: ok -- $pass case(s)$( (( skipped > 0 )) && echo " ($skipped skipped)")"
