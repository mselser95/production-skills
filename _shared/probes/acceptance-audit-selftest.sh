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
#
# EXIT CONTRACT (a pass over nothing is never reported as a pass):
#   0  the cases ran and all passed ("ok -- N case(s)")
#   1  a case failed, or no case ran
#   2  UNDECIDABLE, nothing run: no reference to tell stock from customised (unstamped repo and
#      no installed template, or an installed template of unknown age that differs)
#   3  SKIPPED, nothing run: the repo's scripts/changed-line-coverage.sh differs from the template
#      copy it was STAMPED from, so it is repo-customised and template-format stubs cannot drive it.
# Callers (the template's `probe-selftests`, this repo's `make selftests`) run `bash <this>` and
# treat any non-zero exit as not-passed; they do not count 3 as a pass.
# The thing under test is always the repo's OWN Makefile and script; the reference it is compared
# with is the template version the repo was stamped from (provenance), never "whatever is installed".
if [[ "$own" = 1 ]]; then
  clc="$root/scripts/changed-line-coverage.sh"
  prov="$root/.prod/template-provenance.yaml"
  stamped=""; stamp_from=""
  if [[ -f "$prov" ]]; then
    stamp_from="$(awk '/^stamped_from:/ { print $2; exit }' "$prov")"
    stamped="$(awk '/^[[:space:]]*-[[:space:]]*path:/ { sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, ""); cur=$0; next }
      cur == "scripts/changed-line-coverage.sh" && /template_sha256:/ { sub(/.*template_sha256:[[:space:]]*/, ""); print $1; exit }' "$prov")"
  fi
  if [[ -n "$stamped" ]]; then
    # the reference is the template copy recorded at stamp time (CI has no template installed)
    if [[ "$(shasum -a 256 "$clc" | awk '{print $1}')" != "$stamped" ]]; then
      echo "acceptance-audit selftest: SKIPPED (NOT RUN, 0 case(s)) -- scripts/changed-line-coverage.sh differs from the template copy it was stamped from (${stamp_from:-unknown digest}); it is repo-customised and the recipe is exercised by make acceptance-audit itself"
      exit 3
    fi
  else
    # no stamp entry: the only reference is an installed template of UNKNOWN age
    tdir="${TEMPLATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/prod-new/template}"
    tcl="$tdir/scripts/changed-line-coverage.sh"
    if [[ ! -f "$tcl" ]]; then
      echo "acceptance-audit selftest: UNDECIDABLE (NOT RUN, 0 case(s)) -- no reference is available: no .prod/template-provenance.yaml entry for scripts/changed-line-coverage.sh and no template at $tdir"
      exit 2
    fi
    if ! cmp -s "$clc" "$tcl"; then
      n="$(diff "$clc" "$tcl" 2>/dev/null | wc -l | tr -d ' ')"
      echo "acceptance-audit selftest: UNDECIDABLE (NOT RUN, 0 case(s)) -- no reference is available: this repo records no stamp for scripts/changed-line-coverage.sh and the installed template at $tdir (age unknown) differs by $n diff lines, which is either a customised script or an older/newer template; stamp the repo (scripts/stamp-template-provenance.sh) to say which"
      exit 2
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

# mkstub <repo> <exit-code> : the go stub lives at $r/gopath/bin/go and OWNS GOPATH. Makefiles
# commonly do `export PATH := $(shell go env GOPATH)/bin:$(PATH)`; a stub that answered
# nothing turned that into `/bin:...`, so on runners with /bin/go (Ubuntu) the REAL go won.
mkstub() {
  local r="$1"
  mkdir -p "$r/gopath/bin"
  {
    printf '#!/bin/sh\nif [ "$1" = env ]; then shift; for a in "$@"; do case "$a" in GOPATH) echo "%s";; GOBIN) echo "%s/bin";; esac; done; exit 0; fi\n' "${STUB_GOPATH:-$r/gopath}" "${STUB_GOPATH:-$r/gopath}"
    # The cases below can ask the stub to record its argv (STUB_LOG), to behave like an
    # instrumented-binary acceptance run (STUB_COUNTERS=1 writes a covcounters file into the
    # directory held by the variable STUB_ENVNAME names), to fail that run (STUB_TEST_RC), and to
    # answer `go tool covdata textfmt` (STUB_COVDATA_RC, STUB_COVDATA_PROFILE). Unset, the stub is
    # what it always was: it writes a profile for -coverprofile and exits 0.
    cat <<'EOS'
[ -z "${STUB_LOG:-}" ] || echo "go $*" >> "$STUB_LOG"
if [ "$1" = tool ] && [ "$2" = covdata ]; then
  for a in "$@"; do case "$a" in -i=*) in_dir="${a#-i=}";; -o=*) out="${a#-o=}";; esac; done
  [ -z "${STUB_LOG:-}" ] || echo "covdata-in $in_dir" >> "$STUB_LOG"
  [ "${STUB_COVDATA_RC:-0}" = 0 ] || exit "$STUB_COVDATA_RC"
  printf '%b' "${STUB_COVDATA_PROFILE-mode: set\n}" > "$out"
  exit 0
fi
if [ "$1" = test ] && [ -n "${STUB_ENVNAME:-}" ]; then
  d="$(printenv "$STUB_ENVNAME")"
  [ -z "${STUB_LOG:-}" ] || echo "env $STUB_ENVNAME=$d" >> "$STUB_LOG"
  if [ "${STUB_COUNTERS:-0}" = 1 ] && [ -d "$d" ]; then : > "$d/covcounters.stub.1.1"; fi
fi
[ "${STUB_PROFILE:-1}" = 1 ] && for a in "$@"; do case "$a" in -coverprofile=*) echo "mode: atomic" > "${a#-coverprofile=}";; esac; done
[ -z "${STUB_TEST_RC:-}" ] || exit "$STUB_TEST_RC"
EOS
    printf 'exit %s\n' "$2"
  } > "$r/gopath/bin/go"
  chmod +x "$r/gopath/bin/go"
}

# mkrepo <name> <specs 0|1> : scratch repo, base tag on the first commit
mkrepo() {
  local r="$tmp/$1"; mkdir -p "$r/scripts" "$r/acceptance"
  cp "$mk" "$r/Makefile"
  cp -R "$src/scripts/." "$r/scripts/"
  rm -rf "$r/scripts/tests"
  mkdir -p "$r/.github"; cp "$src/.github/ci-tools.txt" "$r/.github/"
  mkstub "$r" 0
  printf '#!/bin/sh\necho "changed-line coverage: $STUB_OUT lines)"\n' > "$r/scripts/changed-line-coverage.sh"
  [[ "$2" = 1 ]] && : > "$r/acceptance/x.yaml"
  echo "package a" > "$r/a.go"
  ( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m base && git tag base )
  echo "$r"
}

# run <name> <want-rc> <want-substr> <repo> [VAR=val ...]
run() {
  local name="$1" wrc="$2" want="$3" r="$4"; shift 4
  local out rc
  out="$(cd "$r" && env PATH="$r/gopath/bin:$PATH" GOPATH="$r/gopath" CHANGED_LINE_COVERAGE_BASE=base "$@" make --no-print-directory acceptance-audit 2>&1)"; rc=$?
  if [[ "$rc" -eq "$wrc" && "$out" == *"$want"* ]]; then pass=$((pass+1)); echo "  ok   $name"
  else bad=$((bad+1)); echo "  FAIL $name (rc=$rc want $wrc, wanted '$want')"; echo "$out" | sed 's/^/       /'; fi
}

# runmk <name> <want-rc> <want-substr> <repo> [make-arg ...] : as run, with make command-line assignments
runmk() {
  local name="$1" wrc="$2" want="$3" r="$4"; shift 4
  local out rc
  out="$(cd "$r" && env PATH="$r/gopath/bin:$PATH" GOPATH="$r/gopath" CHANGED_LINE_COVERAGE_BASE=base STUB_OUT="90.0% (9/10" make --no-print-directory acceptance-audit "$@" 2>&1)"; rc=$?
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

r="$(mkrepo testonly 1)"; echo "package a // t" > "$r/a_test.go"; ( cd "$r" && git add a_test.go )
run "0/0 with only a _test.go changed passes, said" 0 "only test files changed" "$r" STUB_OUT="0% (0/0"
r="$(mkrepo testplusprod 1)"; echo "package a // t" > "$r/a_test.go"; ( cd "$r" && git add a_test.go ); echo "package a // changed" > "$r/a.go"
run "0/0 with a non-test .go AND a test file changed still fails" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0"
r="$(mkrepo testonlynobase 1)"; echo "package a // t" > "$r/a_test.go"; ( cd "$r" && git add a_test.go )
run "0/0 test-only diff with base missing still fails closed" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0" CHANGED_LINE_COVERAGE_BASE=nosuchbase

# ACCEPTANCE_AUDIT_EXCLUDES: extra pathspec exclusions for the measured set. The recipe hands
# them to changed-line-coverage.sh as CHANGED_LINE_EXTRA_EXCLUDES, and a 0/0 whose only
# non-test Go changes are excluded files is said, not failed; every other 0/0 still fails.
AUD_EXC=':(exclude,glob)test/** :(exclude,glob)**/*test/**'
r="$(mkrepo exclpass 1)"
printf '#!/bin/sh\necho "excludes-seen=[$CHANGED_LINE_EXTRA_EXCLUDES]"\necho "changed-line coverage: $STUB_OUT lines)"\n' > "$r/scripts/changed-line-coverage.sh"
echo "package a // c" > "$r/a.go"
run "ACCEPTANCE_AUDIT_EXCLUDES reaches changed-line-coverage.sh as CHANGED_LINE_EXTRA_EXCLUDES" 0 "excludes-seen=[$AUD_EXC]" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"
run "ACCEPTANCE_AUDIT_EXCLUDES unset passes an empty CHANGED_LINE_EXTRA_EXCLUDES" 0 "excludes-seen=[]" "$r" STUB_OUT="90.0% (9/10"
r="$(mkrepo exclonly 1)"; mkdir -p "$r/test"; echo "package h" > "$r/test/h.go"; echo "package a // t" > "$r/a_test.go"; ( cd "$r" && git add test/h.go a_test.go )
run "0/0 with only tests and excluded files changed passes, said" 0 "only test files and files excluded by ACCEPTANCE_AUDIT_EXCLUDES changed" "$r" STUB_OUT="0% (0/0" ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"
run "...and says how many non-test Go files the exclusions removed (1)" 0 "removed 1 changed non-test Go file(s) from the audit" "$r" STUB_OUT="0% (0/0" ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"
run "0/0 with only an excluded file changed and NO exclusions set still fails" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0"
r="$(mkrepo exclplusprod 1)"; mkdir -p "$r/test"; echo "package h" > "$r/test/h.go"; ( cd "$r" && git add test/h.go ); echo "package a // changed" > "$r/a.go"
run "0/0 with exclusions set but a production file also changed still fails" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0" ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"
r="$(mkrepo exclnobase 1)"; mkdir -p "$r/test"; echo "package h" > "$r/test/h.go"; ( cd "$r" && git add test/h.go )
run "0/0 excluded-only diff with base missing still fails closed" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0" CHANGED_LINE_COVERAGE_BASE=nosuchbase ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"

# W2: an exclusion that eats production code must be visible in the audit's own output. The
# sentence names the exclusions and how many changed non-test Go files they removed.
r="$(mkrepo exclall 1)"; echo "package a // c" > "$r/a.go"; echo "package b" > "$r/b.go"; ( cd "$r" && git add b.go )
run "an exclusion where *.go swallows every production file is refused as a catch-all (was: 0/0 said, rc 0)" 2 "ACCEPTANCE_AUDIT_EXCLUDES excludes every delivered Go file; nothing would be measured" "$r" STUB_OUT="0% (0/0" ACCEPTANCE_AUDIT_EXCLUDES=":(exclude)*.go"
r="$(mkrepo excldrop 1)"; mkdir -p "$r/internal"; echo "package i" > "$r/internal/x.go"; ( cd "$r" && git add internal/x.go )
run "nonzero denominator with exclusions prints the removed-file count line" 0 "exclusions [:(exclude,glob)internal/**] removed 1 changed non-test Go file(s) from the audit" "$r" STUB_OUT="100.0% (3/3" ACCEPTANCE_AUDIT_EXCLUDES=":(exclude,glob)internal/**"
r="$(mkrepo exclnone 1)"; echo "package a // c" > "$r/a.go"
run "no exclusions set: no removed-file line" 0 ">= 80% floor" "$r" STUB_OUT="90.0% (9/10"
# M2: exclusions set and the audit still falls below the floor (dead production code not excluded)
r="$(mkrepo excllow 1)"; mkdir -p "$r/test"; echo "package h" > "$r/test/h.go"; ( cd "$r" && git add test/h.go ); echo "package a // c" > "$r/a.go"
run "exclusions set, delivered code still below the floor fails" 2 "50.0% of changed lines executed by the acceptance run < 80% floor" "$r" STUB_OUT="50.0% (5/10" ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"

# W1: the values are DATA. A marker file must never appear whatever the value holds.
nomarker() { # nomarker <name> <marker>
  if [[ ! -e "$2" ]]; then pass=$((pass+1)); echo "  ok   $1"; else bad=$((bad+1)); echo "  FAIL $1 (marker file was created: shell ran the value)"; rm -f "$2"; fi
}
r="$(mkrepo inject 1)"; cp "$root/scripts/changed-line-coverage.sh" "$r/scripts/changed-line-coverage.sh"; echo "package a // c" > "$r/a.go"
run "quote-breaking exclusion value is refused, fails closed" 2 "refusing CHANGED_LINE_EXTRA_EXCLUDES entry" "$r" ACCEPTANCE_AUDIT_EXCLUDES=":!x';touch $r/PWNED;'"
nomarker "quote-breaking exclusion value executed nothing" "$r/PWNED"
r="$(mkrepo injstub 1)"; echo "package a // c" > "$r/a.go"
printf '#!/bin/sh\necho "excludes-seen=[$CHANGED_LINE_EXTRA_EXCLUDES]"\necho "changed-line coverage: $STUB_OUT lines)"\n' > "$r/scripts/changed-line-coverage.sh"
run '$(...) in a value reaches the script literally' 0 'excludes-seen=[:!$(touch '"$r"'/M1)]' "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':!$(touch '"$r"'/M1)'
nomarker '$(...) in a value executed nothing' "$r/M1"
run "backtick in a value reaches the script literally" 0 'excludes-seen=[:!`touch '"$r"'/M2`]' "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':!`touch '"$r"'/M2`'
nomarker "backtick in a value executed nothing" "$r/M2"
run '$HOME in a value is not expanded' 0 'excludes-seen=[:!$HOME/x]' "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':!$HOME/x'
run "a glob in a value is not shell-expanded: the literal *.go reached git as a pathspec and swallowed everything (catch-all refusal)" 2 "ACCEPTANCE_AUDIT_EXCLUDES excludes every delivered Go file; nothing would be measured" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)*.go'
r="$(mkrepo injnl 1)"; cp "$root/scripts/changed-line-coverage.sh" "$r/scripts/changed-line-coverage.sh"
run "newline between two valid entries: both applied" 0 "excluding from the changed-line set: :!a :!b" "$r" ACCEPTANCE_AUDIT_EXCLUDES=$':!a\n:!b'
run "newline then a non-pathspec: refused, fails closed" 2 "refusing CHANGED_LINE_EXTRA_EXCLUDES entry 'notapathspec'" "$r" ACCEPTANCE_AUDIT_EXCLUDES=$':!a\nnotapathspec'
# An absolute path in an exclusion is refused before anything is measured: a pathspec is
# repo-relative, so /abs/x never matches and the entry silently excludes nothing.
ABSMSG="acceptance-audit: FAIL -- ACCEPTANCE_AUDIT_EXCLUDES entry is an absolute path"
r="$(mkrepo excabs 1)"; echo "package a // c" > "$r/a.go"
run "absolute path after :! is refused, fails closed" 2 "$ABSMSG" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':!/abs/x.go'
run "absolute path after :(exclude,glob) magic is refused, fails closed" 2 "$ABSMSG" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)/abs/**'
run "absolute path as the second of two entries is refused" 2 "$ABSMSG" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=$':!ok/x\n:^/abs/y'
run "a repo-relative entry is not mistaken for an absolute path" 0 ">= 80% floor" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)internal/**'
run "the top-of-tree magic :/x is a relative pathspec, not refused" 0 ">= 80% floor" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':/x'
r="$(mkrepo injfloor 1)"; echo "package a // c" > "$r/a.go"
run "quote-breaking floor is refused, fails closed" 2 "ACCEPTANCE_AUDIT_FLOOR is not a plain number" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_FLOOR="80\";touch $r/F1;\""
nomarker "quote-breaking floor executed nothing" "$r/F1"
run "non-numeric floor is refused (a text floor would compare as 0 and always pass)" 2 "ACCEPTANCE_AUDIT_FLOOR is not a plain number" "$r" STUB_OUT="1.0% (1/100" ACCEPTANCE_AUDIT_FLOOR="high"
run "quote-breaking cover dir is refused, fails closed" 2 "ACCEPTANCE_AUDIT_COVER_DIR contains" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_COVER_DIR="x\";touch $r/C1;\""
nomarker "quote-breaking cover dir executed nothing" "$r/C1"

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
mkstub "$r" 1
run "failing acceptance run with a profile still fails" 2 "Error" "$r" STUB_OUT="90.0% (9/10"

# CI condition: Makefile exports PATH from `go env GOPATH`, and a decoy go sits on PATH
# where the old (GOPATH-less stub) resolution would have found it. Stub must win.
r="$(mkrepo gopathidiom 1)"; echo "package a // c" > "$r/a.go"
mkdir -p "$r/decoy/bin"; printf '#!/bin/sh\necho "DECOY GO RAN"\nexit 1\n' > "$r/decoy/bin/go"; chmod +x "$r/decoy/bin/go"
{ echo 'export PATH := $(shell go env GOPATH)/bin:$(PATH)'; cat "$r/Makefile"; } > "$r/Makefile.new"; mv "$r/Makefile.new" "$r/Makefile"
run "Makefile exporting PATH from go env GOPATH still reaches the stub, not a decoy" 0 ">= 80% floor" "$r" STUB_OUT="90.0% (9/10" PATH="$r/gopath/bin:$r/decoy/bin:$PATH"

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

# The documented ways to set ACCEPTANCE_AUDIT_EXCLUDES are a line in the downstream Makefile and
# a make command-line assignment, NOT the environment every case above uses. Both must reach
# changed-line-coverage.sh (dropping the variable from the Makefile's `export` left every
# environment-driven case green).
SEEN='#!/bin/sh\necho "excludes-seen=[$CHANGED_LINE_EXTRA_EXCLUDES]"\necho "changed-line coverage: $STUB_OUT lines)"\n'
r="$(mkrepo exclmk 1)"; printf "$SEEN" > "$r/scripts/changed-line-coverage.sh"; echo "package a // c" > "$r/a.go"
printf 'ACCEPTANCE_AUDIT_EXCLUDES := %s\n' "$AUD_EXC" >> "$r/Makefile"
run "ACCEPTANCE_AUDIT_EXCLUDES set by a line in the Makefile reaches the measurement" 0 "excludes-seen=[$AUD_EXC]" "$r" STUB_OUT="90.0% (9/10"
r="$(mkrepo exclcli 1)"; printf "$SEEN" > "$r/scripts/changed-line-coverage.sh"; echo "package a // c" > "$r/a.go"
runmk "ACCEPTANCE_AUDIT_EXCLUDES set on the make command line reaches the measurement" 0 "excludes-seen=[$AUD_EXC]" "$r" "ACCEPTANCE_AUDIT_EXCLUDES=$AUD_EXC"
r="$(mkrepo exclmkz 1)"; mkdir -p "$r/test"; echo "package h" > "$r/test/h.go"; ( cd "$r" && git add test/h.go )
printf 'ACCEPTANCE_AUDIT_EXCLUDES := %s\n' "$AUD_EXC" >> "$r/Makefile"
run "a Makefile-line exclusion lets a 0/0 with only excluded files pass, said" 0 "excluded by ACCEPTANCE_AUDIT_EXCLUDES" "$r" STUB_OUT="0% (0/0"

# The removed-file count is over the range the measurement uses (BASE...HEAD, merge-base), so a
# base that is NOT an ancestor does not inflate it with files only the base side changed: here the
# true number is 1 (test/h.go); a working-tree two-dot diff against `div` counted 3.
r="$(mkrepo diverged 1)"; printf "$SEEN" > "$r/scripts/changed-line-coverage.sh"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m stub && git tag base0 && main="$(git branch --show-current)" \
  && git checkout -q -b other && mkdir -p test && echo "package y" > test/y1.go && echo "package y" > test/y2.go && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m other && git tag div && git checkout -q "$main" \
  && mkdir -p test && echo "package h" > test/h.go && git add -A && git -c user.email=t@t -c user.name=t commit -q -m head )
run "diverged base: exclusions removed count is over the merge-base range" 0 "removed 1 changed non-test Go file(s)" "$r" STUB_OUT="90.0% (9/10" CHANGED_LINE_COVERAGE_BASE=div ACCEPTANCE_AUDIT_EXCLUDES="$AUD_EXC"
# a stale entry (matches no changed file) is named, not failed
r="$(mkrepo stale-excl 1)"; printf "$SEEN" > "$r/scripts/changed-line-coverage.sh"; echo "package b" > "$r/b.go"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m addb && git tag -f base >/dev/null )
echo "package a // c" > "$r/a.go"; echo "package b // c" > "$r/b.go"; ( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m c )
run "a stale exclusion entry is named and does not fail" 0 "exclusion ':(exclude,glob)x/**' matched no changed file" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)x/**'
run "a stale exclusion alongside a live one: the live one is still counted" 0 "removed 1 changed non-test Go file(s)" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)x/** :(exclude,glob)a.go'
run "...and the stale entry is printed" 0 "exclusion ':(exclude,glob)x/**' matched no changed file" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)x/** :(exclude,glob)a.go'
run "...and the audit figure line is reached" 0 "acceptance-audit: 90.0%" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)x/** :(exclude,glob)a.go'
# catch-all guard: an exclusion set that removes EVERY tracked non-test .go file is refused
run ":!* catch-all is refused" 2 "ACCEPTANCE_AUDIT_EXCLUDES excludes every delivered Go file; nothing would be measured" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':!*'
run "(exclude,glob)**/*.go catch-all is refused" 2 "ACCEPTANCE_AUDIT_EXCLUDES excludes every delivered Go file; nothing would be measured" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)**/*.go'
run "boundary: exclusions leaving exactly one delivered file pass" 0 "removed 1 changed non-test Go file(s)" "$r" STUB_OUT="90.0% (9/10" ACCEPTANCE_AUDIT_EXCLUDES=':(exclude,glob)b.go'
r="$(mkrepo nogo 1)"; ( cd "$r" && git rm -q a.go && git -c user.email=t@t -c user.name=t commit -q -m nogo )
out="$(cd "$r" && env PATH="$r/gopath/bin:$PATH" GOPATH="$r/gopath" CHANGED_LINE_COVERAGE_BASE=base STUB_OUT="100% (0/0" ACCEPTANCE_AUDIT_EXCLUDES=':!*' make --no-print-directory acceptance-audit 2>&1)"
if [[ "$out" != *"excludes every delivered Go file"* ]]; then pass=$((pass+1)); echo "  ok   zero tracked non-test .go files: exclusions are not the catch-all"; else bad=$((bad+1)); echo "  FAIL zero tracked non-test .go files: exclusions are not the catch-all"; fi
# uncommitted Go changes are NOT in the measured range: a 0/0 over them stays a failure
r="$(mkrepo dirty00 1)"; echo "package a // dirty" > "$r/a.go"
run "0/0 with only UNCOMMITTED non-test Go changes still fails closed" 2 "unmeasurable" "$r" STUB_OUT="0% (0/0"

# BINARY COVERAGE MODE (ACCEPTANCE_AUDIT_BINARY_COVER_ENV) and ACCEPTANCE_AUDIT_TIMEOUT. The stub
# records its argv in $r/stub.log; chk <name> <rc> asserts on what it recorded.
chk() { if [[ "$2" -eq 0 ]]; then pass=$((pass+1)); echo "  ok   $1"; else bad=$((bad+1)); echo "  FAIL $1"; fi; }
BPROF='mode: set\nexample.test/svc/cmd/svc/main.go:3.1,5.2 2 1\nexample.test/svc/internal/e2e/h.go:3.1,5.2 2 1\n'
BENVS=(ACCEPTANCE_AUDIT_BINARY_COVER_ENV=SVC_COVDIR STUB_ENVNAME=SVC_COVDIR)
r="$(mkrepo bin-ok 1)"; echo "package a // c" > "$r/a.go"
run "binary mode: counters + a service file in the profile passes with the floor line" 0 "acceptance-audit: 90.0% >= 80% floor over 1 spec(s)" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COUNTERS=1 STUB_COVDATA_PROFILE="$BPROF" STUB_OUT="90.0% (9/10"
grep -qE '^go test .*-tags=integration .*\./internal/e2e/\.\.\.$' "$r/stub.log" && [[ "$(grep -E '^go test ' "$r/stub.log")" != *-coverprofile* && "$(grep -E '^go test ' "$r/stub.log")" != *-coverpkg* ]]; crc=$?; chk "binary mode: go test got no -coverprofile and no -coverpkg" "$crc"
d="$(sed -n 's/^env SVC_COVDIR=//p' "$r/stub.log")"; crc=1; [[ "$d" == /*/.prod/coverage/binary ]] && crc=0; chk "binary mode: the env var held an absolute path under the cover dir" "$crc"
grep -qx "covdata-in $d" "$r/stub.log"; crc=$?; chk "binary mode: covdata read the directory the env var named" "$crc"
r="$(mkrepo bin-nocnt 1)"; echo "package a // c" > "$r/a.go"
run "binary mode: no counters written fails, naming the cause" 2 "no coverage counters were written: the service binary was not instrumented" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COVDATA_PROFILE="$BPROF" STUB_OUT="90.0% (9/10"
grep -q covdata "$r/stub.log"; crc=$?; chk "binary mode: no counters means covdata is not even run" $((crc == 0))
r="$(mkrepo bin-covdata 1)"; echo "package a // c" > "$r/a.go"
run "binary mode: covdata exiting non-zero fails, naming covdata" 2 "go tool covdata textfmt exited non-zero" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COUNTERS=1 STUB_COVDATA_RC=1 STUB_COVDATA_PROFILE="$BPROF" STUB_OUT="90.0% (9/10"
r="$(mkrepo bin-harness 1)"; echo "package a // c" > "$r/a.go"
run "binary mode: a profile naming only test-support files fails: the service was not measured" 2 "the profile names no file outside the test-support packages: the service was not measured" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COUNTERS=1 STUB_OUT="90.0% (9/10" STUB_COVDATA_PROFILE='mode: set\nexample.test/svc/internal/e2e/h.go:1.1,2.2 1 1\nexample.test/svc/internal/e2etest/k.go:1.1,2.2 1 1\nexample.test/svc/x/y_test.go:1.1,2.2 1 1\nexample.test/svc/x/testdata/z.go:1.1,2.2 1 1\n'
run "binary mode: an empty covdata profile still hits the existing no-profile failure" 2 "wrote no coverage profile" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COUNTERS=1 STUB_OUT="90.0% (9/10" STUB_COVDATA_PROFILE=''
r="$(mkrepo bin-rcfail 1)"; echo "package a // c" > "$r/a.go"
run "binary mode: a failing acceptance run fails the target though counters exist" 2 "Error 7" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_COUNTERS=1 STUB_TEST_RC=7 STUB_COVDATA_PROFILE="$BPROF" STUB_OUT="90.0% (9/10"
r="$(mkrepo bin-0spec 0)"
run "binary mode: 0 specs still says so" 0 "0 specs -- nothing to audit yet" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_OUT="0% (0/0"
r="$(mkrepo bin-stale 1)"; echo "package a // c" > "$r/a.go"; mkdir -p "$r/.prod/coverage/binary"; : > "$r/.prod/coverage/binary/covcounters.old.1.1"
run "binary mode: counters left by an earlier run do not satisfy it" 2 "no coverage counters were written" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" STUB_OUT="90.0% (9/10"
nm=0
for bad_name in 'A B' 'A;touch pwned' '$(touch pwned)' 'A=B' '1A' 'A`touch pwned`' 'A"B'; do
  nm=$((nm+1)); r="$(mkrepo bin-badname-$nm 1)"
  run "invalid ACCEPTANCE_AUDIT_BINARY_COVER_ENV [$bad_name] is refused, value not echoed" 2 "ACCEPTANCE_AUDIT_BINARY_COVER_ENV is not a plain environment variable name" "$r" ACCEPTANCE_AUDIT_BINARY_COVER_ENV="$bad_name" STUB_LOG="$r/stub.log" STUB_OUT="90.0% (9/10"
  crc=1; [[ ! -e "$r/pwned" && ! -e "$r/B" ]] && crc=0; chk "invalid env name [$bad_name]: nothing was executed" "$crc"
  echoed="$( cd "$r" && env PATH="$r/gopath/bin:$PATH" GOPATH="$r/gopath" ACCEPTANCE_AUDIT_BINARY_COVER_ENV="$bad_name" make --no-print-directory acceptance-audit 2>&1 )"
  crc=1; [[ "$echoed" != *"$bad_name"* ]] && crc=0; chk "invalid env name [$bad_name]: the value is not echoed" "$crc"
done
r="$(mkrepo bin-nl 1)"
run "a newline in ACCEPTANCE_AUDIT_BINARY_COVER_ENV is refused" 2 "is not a plain environment variable name" "$r" ACCEPTANCE_AUDIT_BINARY_COVER_ENV="$(printf 'A\ntouch pwned')"
for bad_t in '30' '30m; touch pwned' '30mm' 'm' '30x' '$(touch pwned)' '-5m'; do
  nm=$((nm+1)); r="$(mkrepo tmo-bad-$nm 1)"
  run "invalid ACCEPTANCE_AUDIT_TIMEOUT [$bad_t] is refused" 2 "ACCEPTANCE_AUDIT_TIMEOUT is not a duration like 30m" "$r" ACCEPTANCE_AUDIT_TIMEOUT="$bad_t" STUB_OUT="90.0% (9/10"
  crc=1; [[ ! -e "$r/pwned" ]] && crc=0; chk "invalid timeout [$bad_t]: nothing was executed" "$crc"
done
r="$(mkrepo tmo-bin 1)"; echo "package a // c" > "$r/a.go"
run "valid timeout in binary mode passes" 0 "floor over 1 spec(s)" "$r" "${BENVS[@]}" STUB_LOG="$r/stub.log" ACCEPTANCE_AUDIT_TIMEOUT=30m STUB_COUNTERS=1 STUB_COVDATA_PROFILE="$BPROF" STUB_OUT="90.0% (9/10"
grep -qE '^go test -count=1 -tags=integration -timeout 30m \./internal/e2e/\.\.\.$' "$r/stub.log"; crc=$?; chk "binary mode: ACCEPTANCE_AUDIT_TIMEOUT=30m reaches go test as -timeout 30m" "$crc"
r="$(mkrepo tmo-inproc 1)"; echo "package a // c" > "$r/a.go"
run "valid timeout in the default mode passes" 0 "floor over 1 spec(s)" "$r" ACCEPTANCE_AUDIT_TIMEOUT=2h STUB_LOG="$r/stub.log" STUB_OUT="90.0% (9/10"
grep -qxF 'go test -count=1 -tags=integration -timeout 2h -coverpkg=./... -coverprofile=.prod/coverage/acceptance.out ./internal/e2e/...' "$r/stub.log"; crc=$?; chk "default mode: ACCEPTANCE_AUDIT_TIMEOUT=2h reaches go test as -timeout 2h" "$crc"
# the unset path is what it was before binary mode existed: this argv is the one the previous
# recipe produced (recorded from it before the change), and covdata is never called
r="$(mkrepo unset-argv 1)"; echo "package a // c" > "$r/a.go"
run "default mode, nothing set: passes" 0 "floor over 1 spec(s)" "$r" STUB_LOG="$r/stub.log" STUB_OUT="90.0% (9/10"
grep -qxF 'go test -count=1 -tags=integration -coverpkg=./... -coverprofile=.prod/coverage/acceptance.out ./internal/e2e/...' "$r/stub.log"; crc=$?; chk "default mode: the go test argv is exactly the previous one" "$crc"
grep -q covdata "$r/stub.log"; crc=$?; chk "default mode: go tool covdata is never called" $((crc == 0))
crc=1; [[ ! -e "$r/.prod/coverage/binary" ]] && crc=0; chk "default mode: no binary coverage directory is created" "$crc"

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
  ncases=$pass   # the nested copy runs exactly the cases above (it skips this block)
  mkdir -p "$tmp/nrepo"; cp -R "$root/." "$tmp/nrepo/"; mkdir -p "$tmp/nrepo/scripts/tests"
  cp "${BASH_SOURCE[0]}" "$tmp/nrepo/scripts/tests/acceptance-audit-selftest.sh"
  mkdir -p "$tmp/nhome" "$tmp/nrepo/.prod"
  nclc="$tmp/nrepo/scripts/changed-line-coverage.sh"
  # (i) stock per the stamp, template unresolvable: the cases run, no TEMPLATE_DIR needed.
  printf 'stamped_from: production-skills@abc123def456\nfiles:\n  - path: scripts/changed-line-coverage.sh\n    sha256: x\n    template_sha256: %s\n' \
    "$(shasum -a 256 "$nclc" | awk '{print $1}')" > "$tmp/nrepo/.prod/template-provenance.yaml"
  nested "stamped-stock changed-line-coverage.sh runs the cases without a template" 0 "ok -- $ncases case(s)" "/nonexistent"
  # (i-b) stamped stock, an installed template that DIFFERS (older/newer): the stamp is the reference, the cases still run.
  mkdir -p "$tmp/oldtpl/scripts"; echo "# an older template" > "$tmp/oldtpl/scripts/changed-line-coverage.sh"
  nested "stamped-stock wins over an installed template of a different age: cases run" 0 "ok -- $ncases case(s)" "$tmp/oldtpl"
  # (ii) one comment line added: differs from the stamped template copy -> SKIPPED (not a pass), rc3, names the stamp.
  echo "# customised" >> "$nclc"
  nested "stamped-customised changed-line-coverage.sh is SKIPPED (not run), rc3, naming the stamp" 3 "SKIPPED (NOT RUN, 0 case(s)) -- scripts/changed-line-coverage.sh differs from the template copy it was stamped from (production-skills@abc123def456)" "/nonexistent"
  # (iii) stamp present but no entry for the script, no template: undecidable -> rc2.
  printf 'files:\n  - path: scripts/other.sh\n    sha256: x\n    template_sha256: y\n' > "$tmp/nrepo/.prod/template-provenance.yaml"
  nested "no provenance entry and no template is rc2, no reference" 2 "no reference is available" "/nonexistent"
  rm -rf "$tmp/nrepo/.prod"
  nested "unstamped + customised against an installed template is rc2, not a pass" 2 "installed template at $root (age unknown) differs" "$root"
  nested "unstamped + older installed template that differs is rc2, not a pass" 2 "no reference is available" "$tmp/oldtpl"
  nested "unstamped scaffold, TEMPLATE_DIR unset, nothing installed: rc2, not a silent pass" 2 "UNDECIDABLE (NOT RUN, 0 case(s))" ""
  cp "$root/scripts/changed-line-coverage.sh" "$nclc"
  nested "unstamped + stock matching the installed template: the cases run" 0 "ok -- $ncases case(s)" "$root"
fi

# "N case(s)" is the shape scripts/mutation-baseline.sh reads the count from;
# "N passed, M failed" was invisible to it (found when the baseline refused).
if (( pass == 0 && skipped > 0 )); then echo "acceptance-audit selftest: nothing was measured -- 0 case(s) run, $skipped skipped"; exit 2; fi
if (( pass == 0 )); then echo "acceptance-audit selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "acceptance-audit selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "acceptance-audit selftest: ok -- $pass case(s)$( (( skipped > 0 )) && echo " ($skipped skipped)")"
