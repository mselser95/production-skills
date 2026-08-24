#!/usr/bin/env bash
# verify-standard.sh — probe every standard dimension and print PASS/FAIL/NA.
#
# This script's OUTPUT IS THE COMPLETION REPORT. It probes EFFECTS, not
# artifacts: it runs the tools, greps the entrypoints for wiring, and reads the
# spec's ratified declines. See ../verification-probes.md for why.
#
# Usage:  bash verify-standard.sh [repo-root]
# Exit:   0 = every probe PASS or NA; 1 = at least one FAIL.
#
# Language-specific probes assume Go; adapt the marked blocks for other stacks.

set -uo pipefail

# This probe uses `mapfile` and other bash-4 builtins. macOS still ships bash
# 3.2 at /bin/bash, and `#!/usr/bin/env bash` picks up whatever is first on
# PATH -- so on a stock Mac the probe dies with "local: -A: invalid option" or
# "mapfile: command not found" partway through, which reads as a broken repo
# rather than a missing interpreter. Reported by fd1az against
# clcsolutions/marketdata#34 for scripts/coverage-lib.sh; verified: bash
# 3.2.57 rejects `local -A`, bash 5.3.15 accepts it, and the difference on that
# machine was only Homebrew's bash being earlier on PATH.
#
# Say so once, at the top, instead of failing obscurely in the middle.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "verify-standard: needs bash >= 4 (running ${BASH_VERSION})." >&2
  echo "  macOS ships 3.2 at /bin/bash. Install a newer one and put it first on PATH:" >&2
  echo "    brew install bash   # then re-run" >&2
  exit 2
fi
root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root" || exit 2

# --- LANGUAGE GUARD: refuse a repo this probe cannot measure -----------------
#
# Roughly sixty lines of this script are Go: `go build ./...`, `go test`,
# `--include='*.go'`, `//go:build` tags, golangci-lint, Go coverage profiles.
# Pointed at a C++ repo they do not fail because the repo is bad -- they fail
# because the probe cannot read it, and a wall of FAILs that say nothing about
# the code is worse than no run at all. It trains whoever reads it to discount
# the rows, which is how a gate stops being believed.
#
# Measured before claiming it, and the measurement corrected me. Disabling this
# guard and running against clcsolutions/risk-engine (C++/CMake) gives:
#
#     PASS 3   FAIL 52   NA 2
#     VERDICT: INCOMPLETE — 52 probe(s) failed
#
# So the honest reason is the NOISE, not a false green: it does not print
# COMPLETE. 52 rows that report the probe's blind spot instead of the repo train
# whoever reads them to discount the rows, which is how a gate stops being
# believed -- and the one finding buried among them cannot be found.
#
# The pass-by-absence shape is real but narrower than I first wrote. Of the
# three rows that passed, `loc-ratio` reported `test/prod = 0.00` as a PASS
# because it counts *.go files and found none. That row is informational by
# design, and it is now explicitly N/A when there is nothing to measure rather
# than PASS -- a "PASS" over zero measured lines is the shape this refuses.
#
# A gate that cannot measure a dimension must go RED or say N/A out loud, never
# pass quietly. Refusing at the top is the version of that which cannot be
# misread.
#
# So: recognised language or no verdict at all. Adding a language means adding
# its commands, not relaxing this.
PROD_LANG="${PROD_LANG:-}"
if [[ -z "$PROD_LANG" ]]; then
  if [[ -f go.mod ]]; then PROD_LANG=go
  elif [[ -f CMakeLists.txt || -f vcpkg.json || -f conanfile.txt || -f conanfile.py ]]; then PROD_LANG=cpp
  elif [[ -f Cargo.toml ]]; then PROD_LANG=rust
  elif [[ -f pyproject.toml || -f setup.py ]]; then PROD_LANG=python
  elif [[ -f package.json ]]; then PROD_LANG=node
  else PROD_LANG=unknown
  fi
fi
if [[ "$PROD_LANG" != go ]]; then
  echo "verify-standard: this probe implements the GO toolchain only; detected '$PROD_LANG' in $root." >&2
  echo "" >&2
  echo "  Refusing to run rather than emitting ~40 rows that measure the probe's blind spot" >&2
  echo "  instead of the repo, and rather than printing a verdict over dimensions that were" >&2
  echo "  never looked at: the language-agnostic rows (registries, runbook citations, scenario" >&2
  echo "  matrix, observability contracts, SLOs, evidence record) WOULD pass here, and a" >&2
  echo "  COMPLETE verdict on that basis is exactly the false green this standard exists to" >&2
  echo "  refuse." >&2
  echo "" >&2
  echo "  To add a toolchain, give it the equivalent of every language-bound row -- build," >&2
  echo "  unit tests, race (TSan for C++), coverage + per-package ratchet, lint, fuzz, and" >&2
  echo "  benchmarks -- and wire them here. A row with no equivalent must be an explicit," >&2
  echo "  ratified N/A with a reason, never a silent skip." >&2
  echo "" >&2
  echo "  Override with PROD_LANG=go only if this genuinely IS a Go repo the detection missed." >&2
  exit 2
fi

# Two concurrent probe runs in the same repo fight over Go's fuzz cache and
# produce a spurious "setup failed" — serialize on a lock dir instead of
# reporting a false FAIL.
LOCK="${TMPDIR:-/tmp}/prod-probe-$(echo "$root" | shasum | cut -c1-12).lock"
for _ in $(seq 1 120); do mkdir "$LOCK" 2>/dev/null && break; sleep 5; done
# Restore any in-flight mutation before anything else. The non-vacuity check
# below deliberately edits PRODUCTION source files, and a probe killed between
# the edit and its restore would otherwise leave the working tree holding a file
# with a ratified invariant switched off -- plus an untracked backup -- where a
# routine `git add -A` would commit both. The tool that makes the mess has to be
# the tool that cleans it, on every exit path, not just the happy one.
restore_mutations() {
  local bak
  while IFS= read -r bak; do
    [[ -n "$bak" ]] || continue
    mv -f "$bak" "${bak%.nvbak}" 2>/dev/null
  done < <(find . -name '*.nvbak' -type f 2>/dev/null)
}
trap 'restore_mutations; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# ...and ACTUALLY run it now, which the comment above has promised since it was
# written while the function had exactly two references: its definition and the
# trap. The trap cannot catch SIGKILL, and packages 003 and 004 mutate the SAME
# file: killed mid-003, health.go is left with TickFreshnessOK dropped from the
# ready formula, and the NEXT run made it permanent -- 003 bails at
# find-string-gone, but 004's find-string is still present, so its
# `cp "$nv_file" "$nv_file.nvbak"` overwrote the good backup with the already
# mutated file and the closing mv restored the mutation for good.
#
# Restoring first also means a leftover .nvbak can never be silently committed
# by a routine `git add -A` between two runs.
restore_mutations

# nv_package_reason <package> <extracted-fields> -- why this package cannot be
# mutated, or EMPTY if it can. Four distinct reasons, deliberately not merged:
#
#   unparseable          the extractor could not read the file -- an ENVIRONMENT
#                        gap. Reported identically to "no check" once, which
#                        sent a reader to inspect four correct YAML files
#                        instead of the interpreter error in the same log.
#   no-executable-check  the package declares nothing -- an AUTHORING gap.
#   no-such-file         it names a source file that does not exist.
#   find-string-gone     the mutation no longer applies: the evidence DECAYED,
#                        which is not the same as evidence that was never true
#                        but is reported just as loudly.
#
# A function rather than inline branches because the selftest sources it and
# drives all four, instead of grepping this file for their names -- a grep
# cannot tell a branch that works from a branch that is dead, and one of these
# was measured passing against `if false; then`.
nv_package_reason() {
  local pkg="$1" fields="$2" file test find
  [[ "${fields%%$'\n'*}" == "PARSE-ERROR" ]] && { printf 'unparseable'; return; }
  file=$(sed -n 1p <<<"$fields"); test=$(sed -n 2p <<<"$fields"); find=$(sed -n 3p <<<"$fields")
  # A package with no executable check is UNVERIFIED, and unverified is not a
  # softer kind of verified. Tolerating it with a PASS meant three of four
  # invariants could carry nothing at all and the row would still be green as
  # long as one worked -- the same "some evidence exists somewhere" reasoning
  # the keyword grep used.
  [[ -z "$file" || -z "$test" || -z "$find" ]] && { printf 'no-executable-check'; return; }
  [[ -f "$file" ]] || { printf 'no-such-file'; return; }
  FIND="$find" python3 -c 'import os,sys; sys.exit(0 if os.environ["FIND"] in open(sys.argv[1]).read() else 1)' "$file" \
    || { printf 'find-string-gone'; return; }
  return 0
}

# cited_function / executed_function <package> -- the two halves the citation
# row compares, each read through extract_pkg_fields so there is ONE parser.
#
# Split out as functions for the same reason classify_mutation_result was: the
# selftest sources them and drives them against scratch packages, instead of
# grepping this file for a string, which cannot tell a working branch from a
# dead one. Sourcing also means the selftest cannot drift into testing a copy.
cited_function()    { sed -n 6p <<<"$(extract_pkg_fields "$1")"; }
executed_function() { sed -n 2p <<<"$(extract_pkg_fields "$1")"; }

# citation_drift <package> -- prints the drift description, or nothing.
citation_drift() {
  local fn red
  fn=$(cited_function "$1"); red=$(executed_function "$1")
  [[ -z "$fn" ]] && return 0
  [[ "$red" == "$fn" ]] && return 0
  printf '%s:cites=%s,executes=%s' "$(basename "$1")" "$fn" "$red"
}

# extract_pkg_fields <ratify-queue package> -- SIX lines on stdout:
#   file, expect_red, find, replace, requires_tags, test.function
#
# ONE parser for these packages, used by the non-vacuity row and by the
# citation row. See the comment inside for what having two cost.
extract_pkg_fields() {
  PKG="$1" python3 - <<'PYNV' 2>/dev/null
import os, sys

want = ("file", "expect_red", "find", "replace", "requires_tags")
# `function` lives under a `test:` block, not under non_vacuity_check, and
# it is read HERE so there is exactly one parser for these packages. The
# citation check used to re-derive expect_red with awk, and the two
# disagreed in BOTH directions: `expect_red:Foo` (no space) made the awk
# return empty and the drift check silently SKIP while the row printed
# PASS "cited test resolves AND matches", and a legally single-quoted
# `expect_red: 'Foo'` made it report a false FAIL. Two parsers for one
# field is two chances to be wrong about it.
cited = ""
found = {}
inblock = False
intest = False
try:
    lines = open(os.environ["PKG"], encoding="utf-8").read().splitlines(True)
except Exception as exc:                      # unreadable, wrong encoding, gone
    print("PARSE-ERROR", exc, file=sys.stderr)
    print("PARSE-ERROR")
    sys.exit(1)
for raw in lines:
    line = raw.rstrip("\n")
    if line.startswith("non_vacuity_check:"):
        inblock = True
        intest = False
        continue
    if line.startswith("test:"):
        intest = True
        inblock = False
        continue
    if intest:
        if line and not line[0].isspace():
            intest = False
        else:
            s = line.strip()
            if s.startswith("function:"):
                v = s.partition(":")[2].strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                cited = v
            continue
    if inblock:
        # any new top-level key ends the block
        if line and not line[0].isspace():
            break
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        key = key.strip()
        if key not in want:
            continue
        value = value.strip()
        # strip exactly one layer of matching quotes, then unescape a doubled
        # single quote (YAML's own escape inside single-quoted scalars)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            quote = value[0]
            value = value[1:-1]
            if quote == "'":
                value = value.replace("''", "'")
            else:
                # DOUBLE-quoted YAML scalars carry escapes, and Go source is
                # full of tabs -- a find-string written as "\t\tif err != nil {"
                # arrives as a literal backslash-t and never matches, which the
                # probe then reports as find-string-gone: a true verdict for a
                # false reason, and the most confusing kind of finding.
                value = (value.replace("\\t", "\t").replace("\\n", "\n")
                              .replace('\\"', '"').replace("\\\\", "\\"))
        found[key] = value
for k in want:
    print(found.get(k, ""))
print(cited)
PYNV
}

SPEC="${PROD_SPEC_FILE:-production.yaml}"
# Overridable for the SAME reason REGISTRIES_DIR is: the selftest for the
# non-vacuity checker asserted three of its branches by grepping this script's
# own SOURCE TEXT, and a grep cannot tell a branch that works from a branch
# that is dead -- or, worse, from a branch that is the only outcome. With the
# directory injectable, those branches are driven end to end against crafted
# scratch packages instead.
RATIFY_QUEUE_DIR="${RATIFY_QUEUE_DIR:-.prod/ratify-queue}"
fails=0; passes=0; nas=0
declare -a ROWS

# --- helpers -----------------------------------------------------------------
row() { # row <dimension> <verdict> <evidence>
  # A PASS WITH NO EVIDENCE IS A FAIL.
  #
  # Every PASS in this file is supposed to carry the measurement that earned
  # it. When an extractor stops matching, the measurement silently becomes the
  # empty string and the row passes anyway -- the gate reporting green over a
  # number it never read.
  #
  # Not hypothetical. `coverage` extracts with
  # `grep -oE 'TOTAL COVERAGE: [0-9.]+%'`; a coverage.sh printing any other
  # wording (measured against clcsolutions/risk-engine's
  # "TOTAL LINE COVERAGE (src/, hand-written only): 3.10%") yields nothing, and
  # since the script exited 0 the row rendered exactly:
  #
  #     coverage                           PASS
  #
  # over a repo at 3.10% with no floor. This file already calls an
  # evidence-free FAIL "the worst output a probe can produce"; the same defect
  # in the PASS branch is worse, because nobody goes looking.
  #
  # One guard here catches every future extractor drift, not just this one.
  # Found by a reviewer running the probe against a C++ repo -- the language
  # mismatch was the symptom; this was the disease.
  if [[ "$2" == PASS && -z "${3// /}" ]]; then
    ROWS+=("$1|FAIL|passed with NO evidence: the extractor produced nothing, so this row certifies a measurement it never read")
    fails=$((fails+1))
    return
  fi
  ROWS+=("$1|$2|$3")
  case "$2" in PASS) passes=$((passes+1));; FAIL) fails=$((fails+1));; NA) nas=$((nas+1));; esac
}
declined() { # declined <key> -> 0 if the spec ratifies this decline
  [[ -f "$SPEC" ]] && grep -qE "^[[:space:]]*-[[:space:]]*$1:" "$SPEC"
}
waived() { # waived <id> -> 0 if a NON-EXPIRED waiver covers this obligation.
  # An unmet required obligation is legal only as a live waiver with an owner
  # and an expiry — never as a spec key invented to hold it, and never once the
  # expiry has passed (check-registries.sh gates that separately).
  local w=registries/waivers.yaml
  [[ -f $w ]] || return 1
  # Order-INDEPENDENT, matching what check-registries.sh was already fixed to
  # do. This required `id:` to sit on the entry's dash line, so a waiver
  # written `- obligation: ... / id: foo` was expiry-checked correctly by
  # check-registries.sh -- whose comment tells the reader key order no longer
  # matters -- and simultaneously invisible here, making the probe report the
  # dimension FAIL as though no waiver existed. It fails closed, so the cost
  # was a confusing red rather than a bypass; a half-applied fix that
  # contradicts the comment next to it is still a defect.
  #
  # `id:` on its own line, at any indentation, whether or not it follows a
  # dash. The id must be the whole value, so `id: foo-bar` does not satisfy a
  # lookup for `foo`.
  grep -qE "^[[:space:]]*(-[[:space:]]*)?id:[[:space:]]*$1[[:space:]]*$" "$w" || return 1
  bash scripts/check-registries.sh >/dev/null 2>&1
}
# classify_mutation_result turns `go test` output into one of DETECTED /
# MUTATION-BREAKS-BUILD / STAYED-GREEN / NO-VERDICT.
#
# A named function on purpose: it is the part of the non-vacuity check that
# decides whether an invariant has teeth, so a selftest has to exercise THIS,
# not a copy of it. It already regressed once as a copy -- the FAIL test used to
# sit after the ok test, so a sibling package's "ok" line matched first and every
# mutation was reported STAYED-GREEN.
classify_mutation_result() {
  local out="$1"
  # A test that did not RUN is not a verdict, in either direction. Two live
  # traps, both observed: an integration-tagged invariant test without the tag
  # yields "[no test files]" (neither ok nor FAIL -> NO-VERDICT), and WITH the
  # tag but without a database it self-skips and the package prints a bare
  # "ok" -- which would classify the mutation STAYED-GREEN and accuse a
  # perfectly good invariant of being vacuous. Checking for the skip first is
  # what keeps "not run" from masquerading as either answer.
  if grep -qE "^--- SKIP|no tests to run|\[no test files\]" <<<"$out"; then
    echo "NOT-RE-VERIFIED"
  elif grep -qE "build failed|cannot use|undefined:|declared and not used|syntax error" <<<"$out"; then
    echo "MUTATION-BREAKS-BUILD"
  elif grep -qE "^(--- )?FAIL" <<<"$out"; then
    echo "DETECTED"
  elif grep -q "^ok" <<<"$out"; then
    echo "STAYED-GREEN"
  else
    echo "NO-VERDICT"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
gobin() { echo "$(go env GOPATH)/bin"; }

# --- 1. build + tests --------------------------------------------------------
if go build ./... >/dev/null 2>&1; then row "build" PASS "go build ./... clean"
else row "build" FAIL "go build ./... failed"; fi

if out=$(go test ./... -count=1 2>&1); then
  row "tests" PASS "$(grep -c '^ok' <<<"$out") packages ok"
else row "tests" FAIL "$(grep -m1 -E 'FAIL|panic' <<<"$out")"; fi

# Capture the output. "race suite failed" names nothing -- not the test, not
# the package, not whether it was a DATA RACE at all -- so the row sent the
# reader back to re-run the suite themselves, and an INTERMITTENT failure may
# not reproduce on that re-run. Evidence you have to regenerate is evidence you
# may not get.
if race_out=$(go test ./... -race -count=1 2>&1); then
  row "race" PASS "race detector clean"
else
  # The test NAME and the ASSERTION, not one or the other. Reporting only
  # `--- FAIL: TestX` sends the reader to re-run it for the message -- and for
  # an intermittent failure that re-run may come back clean, which is the whole
  # reason this row captures output at all. Measured: a red race row named
  # TestVenueView_LosingAVenueNeverMovesTheDemand and dropped
  # "InQuorum=1, want 3", the number that identified the mechanism.
  race_name=$(grep -m1 -E '^--- FAIL: [A-Za-z0-9_/]+' <<<"$race_out")
  race_assert=$(grep -m1 -E '^[[:space:]]+[^[:space:]]+\.go:[0-9]+:' <<<"$race_out")
  race_why=$(grep -m1 -E '^[[:space:]]*(WARNING: DATA RACE)' <<<"$race_out")
  [[ -z "$race_why" ]] && race_why="$(printf '%s%s' "${race_name}" "${race_assert:+ -- $(printf '%s' "$race_assert" | sed 's/^[[:space:]]*//')}")"
  [[ -z "$race_why" ]] && race_why=$(grep -m1 -E '^FAIL' <<<"$race_out")
  race_pkg=$(grep -m1 -E '^FAIL[[:space:]]+[^[:space:]]+' <<<"$race_out" | awk '{print $2}')
  row "race" FAIL "${race_why:-race suite failed}${race_pkg:+ (in $race_pkg)}"
fi

# --- 2. coverage + per-package ratchet (measured, not claimed) ---------------
if [[ -x scripts/coverage.sh ]]; then
  if out=$(./scripts/coverage.sh 2>&1); then
    row "coverage" PASS "$(grep -oE 'TOTAL COVERAGE: [0-9.]+%' <<<"$out" | head -1)"
    if grep -q "ratchet: all packages at/above" <<<"$out"; then
      row "coverage-ratchet" PASS "per-package floors enforced"
    else row "coverage-ratchet" FAIL "no per-package ratchet in the gate"; fi
  else
    # coverage.sh fails FOUR ways and this branch used to assume one.
    #
    # It reported "$viol floor violation(s): <list>" unconditionally, so when
    # the failure was anything else -- the TOTAL below threshold, a floor
    # naming a package that no longer exists, or the test run itself dying --
    # viol was 0, the list grep matched nothing, and the row rendered exactly
    #
    #     coverage  FAIL  0 floor violation(s):
    #
    # An evidence-free FAIL is the worst output a probe can produce: it names
    # no defect, so the only available "fix" is to soften the probe. Same
    # defect the govulncheck row was already repaired for, and the real cause
    # was sitting in $out the whole time, captured and unused. Reproduced with
    # COVERAGE_MIN=99.9.
    #
    # `| head -1` + `${viol:-0}`: grep -c prints 0 AND exits non-zero on zero
    # matches, so the count needs the same guard the other counting rows in
    # this file carry.
    viol=$(grep -cE 'below its floor' <<<"$out" | head -1); viol=${viol:-0}
    if (( viol > 0 )); then
      row "coverage" FAIL "$viol floor violation(s): $(grep -oE '[a-z/]+ is [0-9.]+%, below its floor of [0-9.]+%' <<<"$out" | paste -sd' ; ' -)"
    elif below=$(grep -m1 -oE 'coverage [0-9.]+% is below [0-9.]+%' <<<"$out"); then
      row "coverage" FAIL "$below"
    elif missing=$(grep -m1 -oE "package '[^']+' has a floor [^,]*but no measured coverage" <<<"$out"); then
      row "coverage" FAIL "$missing (renamed or removed package? update scripts/coverage-floors.txt)"
    else
      # A gate that did not COMPLETE is an unproven gate, not a clean one,
      # so the row has to carry whatever evidence exists. Prefer a real
      # file:line diagnostic -- go test ends a build failure with a bare
      # "FAIL", so "the last non-noise line" alone reported exactly that and
      # was barely better than the empty evidence this branch replaced.
      detail=$(grep -m1 -E '^[^[:space:]]+\.go:[0-9]+:' <<<"$out")
      [[ -n "$detail" ]] || detail=$(grep -vE '^(ok|---|FAIL$|[[:space:]]*$)' <<<"$out" | tail -1)
      row "coverage" FAIL "coverage gate did not complete: $(cut -c1-110 <<<"${detail:-<no output captured>}")"
    fi
  fi
else row "coverage" FAIL "no scripts/coverage.sh"; fi

# tests/prod LOC ratio — recorded, never a gate
prod=$(find . -name '*.go' -not -name '*_test.go' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
tst=$(find . -name '*_test.go' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
# N/A, not PASS, when there is nothing to measure. Found by disabling the
# language guard above and running against a C++ repo: this row printed
# `PASS test/prod = 0.00` because it counts *.go and found none -- a PASS over
# zero measured lines, which is the pass-by-absence shape the guard exists to
# refuse, sitting inside the probe.
if [[ -z "$prod" || "$prod" == 0 ]]; then
  row "loc-ratio (informational)" NA "no non-test Go source measured — nothing to ratio"
else
  row "loc-ratio (informational)" PASS "test/prod = $(awk -v t="$tst" -v p="$prod" 'BEGIN{printf "%.2f", t/p}') ($tst/$prod)"
fi

# --- 3. lint + fitness functions --------------------------------------------
if have golangci-lint || [[ -x "$(gobin)/golangci-lint" ]]; then
  if PATH="$(gobin):$PATH" golangci-lint run --timeout=5m >/dev/null 2>&1; then
    row "lint" PASS "0 issues"
  else row "lint" FAIL "golangci-lint reported issues"; fi
else row "lint" FAIL "golangci-lint not installed"; fi

if ls internal/architecture/*_test.go >/dev/null 2>&1 || grep -rql "forbidden\|ImportsOnly" --include='*_test.go' . 2>/dev/null; then
  if go test ./internal/architecture/... -count=1 >/dev/null 2>&1; then
    empty=$(grep -A3 'wallClockAllowlist = map\[string\]bool{' internal/architecture/*_test.go 2>/dev/null | grep -c '"' || true)
    row "fitness-functions" PASS "architecture test green; wall-clock allowlist entries: $empty"
  else row "fitness-functions" FAIL "architecture test red"; fi
else row "fitness-functions" FAIL "no architecture/fitness test found"; fi

# --- 4. ratified invariants (exist AND run AND provably non-vacuous) --------
if ls verification/ratified/*_test.go >/dev/null 2>&1; then
  n=$(grep -h '^func Test' verification/ratified/*_test.go 2>/dev/null | wc -l | tr -d ' ')
  # The build tags the ratified tests DECLARE, taken from their own `//go:build`
  # lines. This used to be a bare `go test ./verification/...`, which is the
  # purest form of the defect this whole file exists to refuse: the ratified
  # tests carry `//go:build integration`, so an untagged run compiles NONE of
  # them, prints "[no test files]", and exits 0 -- and the row translated that
  # into "N test func(s) green". A gate reporting N green from a run that
  # compiled zero is worse than no gate: it is a gate that certifies its own
  # absence. Measured: exit 0, "verification/ratified [no test files]", row PASS.
  rat_tags=$(grep -h '^//go:build' verification/ratified/*_test.go 2>/dev/null \
    | sed 's|^//go:build||' | tr -c 'A-Za-z0-9_' ' ' \
    | tr ' ' '\n' | sed '/^$/d' | grep -vx 'ignore' | sort -u | tr '\n' ',' | sed 's/,$//')
  # -v and a count, because "exit 0" is not "the tests ran". The run must
  # produce exactly the N top-level PASS lines that N `func Test` promised;
  # anything less means a tag was missing or a test was filtered away, and that
  # is a FAIL rather than a quieter PASS.
  rat_out=$(go test ${rat_tags:+-tags="$rat_tags"} ./verification/ratified/ -count=1 -v 2>&1)
  rat_rc=$?
  rat_ran=$(printf '%s\n' "$rat_out" | grep -cE '^--- (PASS|FAIL): Test')
  rat_pass=$(printf '%s\n' "$rat_out" | grep -cE '^--- PASS: Test')
  if (( n == 0 )); then row "invariants-ratified" FAIL "verification/ratified/ has files but zero Test funcs"
  elif (( rat_ran != n )); then
    row "invariants-ratified" FAIL "$n ratified Test func(s) declared but only $rat_ran ran under -tags='$rat_tags' — a run that compiles none of them exits 0 and proves nothing"
  elif (( rat_rc == 0 && rat_pass == n )); then
    # Count from the SPEC, not from the directory listing. Counting `func Test`
    # in verification/ratified/ and calling the total "ratified" conflated
    # ratified invariants with ones still PENDING HUMAN RATIFICATION whose test
    # simply lives alongside them -- and then wrote that inflated number into
    # every evidence record. Ratification is a human act recorded in the spec;
    # a test file cannot confer it on itself.
    ratified_n=$(awk '/^invariants:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^[[:space:]]*-[[:space:]]/{c++} END{print c+0}' "$SPEC" 2>/dev/null)
    pending_n=$(awk '/^invariants_pending_ratification:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^[[:space:]]*-[[:space:]]/{c++} END{print c+0}' "$SPEC" 2>/dev/null)
    row "invariants-ratified" PASS "$ratified_n ratified per $SPEC (+$pending_n pending human ratification); $rat_pass/$n test func(s) ACTUALLY RAN green under -tags='$rat_tags'"
  else row "invariants-ratified" FAIL "ratified tests red"; fi
  # --- non-vacuity: EXECUTE the mutations, do not grep for the word ----------
  #
  # This row used to be `grep -qi "counterexample\|verified red\|mutation"` over
  # verification/ratified/ and .prod/ratify-queue/ -- a keyword search over prose
  # the change under review had just written. Any repo could satisfy the
  # standard's central claim by typing the word "mutation" in a comment. A
  # reviewer caught it, and they were right: it is the exact defect this whole
  # framework exists to name, sitting in the framework.
  #
  # Now each ratification package may carry an executable `non_vacuity_check`:
  # a file, an exact source string to replace, and the test that MUST go red
  # when it is. The probe applies it, runs that test, requires FAILURE, and
  # restores the file. Keyed by source text rather than line number, because the
  # prose evidence this replaces cited three line numbers that had all moved.
  nv_total=0; nv_proven=0; nv_missing=0; nv_broken=""
  # *.y*ml, matching the two sibling loops over this same directory (the
  # ratification-packages count and the citation loop). Globbing *.yaml here
  # meant a package written .yml was COUNTED by those two and never entered
  # nv_total -- the non-vacuity row reporting green over a set that silently
  # excluded it, which is the shape this row exists to prevent one level up.
  for pkg in "$RATIFY_QUEUE_DIR"/*.y*ml; do
    [[ -f "$pkg" ]] || continue
    # Counted HERE, before the parse. Counting after it meant a package the
    # extractor could not read never reached the denominator, so a directory of
    # unreadable packages produced "no ratification packages to check" rather
    # than naming what was wrong with each one -- the absence looking like an
    # empty directory instead of a failure.
    nv_total=$((nv_total+1))
    # Parsed as YAML, not with sed. The find/replace strings are Go SOURCE, so
    # they routinely contain quotes, backslashes and colons; a sed expression
    # delimited by single quotes silently mis-extracts a rune literal or an
    # apostrophe in a comment, and a mutation that is quietly wrong reports
    # find-string-gone rather than admitting it could not read the field.
    # Extracted with the stdlib only. An earlier version imported yaml and was
    # correct on a dev box and useless in CI, where PyYAML is not installed: the
    # parse returned nothing, every package reported no-executable-check, and
    # the row failed. It failed LOUDLY, which is the only reason this was a
    # ten-minute fix instead of a silent "0/4 verified" -- but a gate that needs
    # a dependency the runner lacks is a gate that does not run.
    #
    # The grammar here is fixed and tiny: five keys under one top-level block,
    # each a single-quoted or bare scalar. That is parseable without a library,
    # and unlike the sed version it handles the quotes and colons that Go source
    # is full of, because it strips exactly one layer of quoting rather than
    # pattern-matching the line.
    # The extractor's own failure is a DISTINCT outcome from "this package
    # declares nothing". Both used to arrive as four empty lines, so a parser
    # that could not run reported `no-executable-check` for four packages that
    # each declared a complete check -- sending the reader to inspect four
    # correct YAML files instead of to the interpreter error a few lines up in
    # the same log. Unverified is not a softer kind of verified, and WHY it is
    # unverified changes where you go next: no check is an authoring gap, a
    # broken parser is an environment gap.
    #
    # So the extractor prints PARSE-ERROR as its first line and exits non-zero
    # on any failure, and that is classified as its own reason.
    nv_fields=$(extract_pkg_fields "$pkg") || nv_fields="PARSE-ERROR"
    nv_reason=$(nv_package_reason "$pkg" "$nv_fields")
    if [[ -n "$nv_reason" ]]; then
      case "$nv_reason" in
        unparseable|no-executable-check) nv_missing=$((nv_missing+1)) ;;
      esac
      nv_broken="${nv_broken} $(basename "$pkg"):${nv_reason}"
      continue
    fi
    nv_reqtags=$(sed -n 5p <<<"$nv_fields")
    nv_file=$(sed -n 1p <<<"$nv_fields")
    nv_test=$(sed -n 2p <<<"$nv_fields")
    nv_find=$(sed -n 3p <<<"$nv_fields")
    nv_repl=$(sed -n 4p <<<"$nv_fields")
    cp "$nv_file" "${nv_file}.nvbak"
    FIND="$nv_find" REPL="$nv_repl" python3 -c 'import os,sys
path=sys.argv[1]; src=open(path).read()
open(path,"w").write(src.replace(os.environ["FIND"], os.environ["REPL"], 1))' "$nv_file"
    # A mutation must make the TEST fail, not the BUILD. `go test` exits
    # non-zero for both, so counting any non-zero as "detected" would let a
    # mutation that merely breaks compilation certify the invariant as
    # non-vacuous -- which is the same class of self-deception this row exists
    # to remove. Compile first, and treat a build break as a decayed mutation.
    # Scope the run to the package that OWNS the expect_red test, and test for
    # FAIL before ok. Both matter, and the second one bit: `./verification/...`
    # spans more than one package, so as soon as a sibling package gained tests
    # its own "ok" line matched first and every mutation was classified
    # STAYED-GREEN -- the probe reporting all four invariants as vacuous when
    # they were not. A classifier that reads a neighbour's verdict is the same
    # defect as a gate that reads a report instead of an effect.
    nv_pkg=./verification/ratified/
    [[ -d verification/ratified ]] || nv_pkg=./verification/...
    # -v so a SKIP is visible: without it a fully-skipped package prints only
    # "ok", which is indistinguishable from a mutation that went undetected.
    nv_tags=""
    [[ -n "${nv_reqtags:-}" ]] && nv_tags="-tags=${nv_reqtags}"
    # shellcheck disable=SC2086
    nv_out=$(go test $nv_tags -v "$nv_pkg" -run "^${nv_test}\$" -count=1 2>&1)
    case "$(classify_mutation_result "$nv_out")" in
      DETECTED)              nv_proven=$((nv_proven+1)) ;;
      *)                     nv_broken="${nv_broken} ${nv_test}:$(classify_mutation_result "$nv_out")" ;;
    esac
    mv "${nv_file}.nvbak" "$nv_file"
  done
  if (( nv_total == 0 )); then
    row "invariants-non-vacuity" FAIL "no ratification packages to check"
  elif [[ -n "$nv_broken" ]]; then
    row "invariants-non-vacuity" FAIL "mutation(s) not detected or decayed:${nv_broken}"
  else
    row "invariants-non-vacuity" PASS "$nv_proven/$nv_total mutations RE-VERIFIED red this run"
  fi
else row "invariants-ratified" FAIL "verification/ratified/ has no tests"; fi

# --- 5. properties + fuzz (each target actually executed) -------------------
# The CONDITION and the EVIDENCE must count the same thing. This used to pass
# on `func TestProperty` OR the bare word `adequacy` appearing in any test
# file, while the evidence string counted only `func TestProperty*` -- so a
# repo that deleted every property test but left the word "adequacy" in a
# comment PASSED, with the evidence reading "0 property tests present". A row
# whose own evidence says zero is a row that has stopped checking.
prop_n=$(grep -rho 'func TestProperty[A-Za-z_]*' --include='*_test.go' . 2>/dev/null | sort -u | wc -l | tr -d ' ')
prop_n=${prop_n:-0}
if (( prop_n > 0 )) && grep -rql 'adequacy' --include='*_test.go' . >/dev/null 2>&1; then
  row "property-tests" PASS "$prop_n property test(s), with generator-adequacy assertion(s)"
elif (( prop_n > 0 )); then
  # A property test whose generator never produces the interesting shape
  # passes vacuously, which is why the standard asks for an explicit adequacy
  # assertion rather than trusting the generator.
  row "property-tests" FAIL "$prop_n property test(s) but no generator-adequacy assertion — an inadequate generator passes vacuously"
else row "property-tests" FAIL "no property tests found (the word 'adequacy' in a test file is not a property test)"; fi

mapfile -t fuzzes < <(grep -rho 'func \(Fuzz[A-Za-z0-9_]*\)' --include='*_test.go' . 2>/dev/null | sed 's/func //' | sort -u)
if ((${#fuzzes[@]})); then
  bad=0; infra=0
  for f in "${fuzzes[@]}"; do
    pkg=$(grep -rl "func $f(" --include='*_test.go' . | head -1 | xargs dirname)
    fout=$(go test -run="^$f\$" -fuzz="^$f\$" -fuzztime=3s "$pkg" 2>&1) || {
      fout=$(go test -run="^$f\$" -fuzz="^$f\$" -fuzztime=3s "$pkg" 2>&1) || {
        if grep -q "setup failed" <<<"$fout"; then infra=$((infra+1)); else bad=$((bad+1)); fi; }; }
  done
  if ((bad==0 && infra==0)); then row "fuzz" PASS "${#fuzzes[@]} targets, all ran clean 3s"
  elif ((bad==0 && infra >= ${#fuzzes[@]})); then
    # EVERY target bucketed as toolchain-infra means NOT ONE was fuzzed, and
    # the old branch reported that as "targets clean". Tolerating some
    # inconclusive runs is reasonable -- Go's fuzz cache genuinely contends
    # under parallel packages -- but tolerating ALL of them turns the row into
    # a report that the tool failed to start, printed as a pass.
    row "fuzz" FAIL "${#fuzzes[@]} targets, ALL inconclusive: no target was actually fuzzed, so this row proves nothing"
  elif ((bad==0)); then row "fuzz" PASS "${#fuzzes[@]} targets, $((${#fuzzes[@]}-infra)) ran clean ($infra inconclusive: toolchain setup, not a finding)"
  else row "fuzz" FAIL "${#fuzzes[@]} targets, $bad genuinely failed"; fi
else row "fuzz" FAIL "no fuzz targets"; fi

# --- 6. mutation baseline (artifact + freshness) ----------------------------
if ls .prod/mutation/baseline-*.md >/dev/null 2>&1; then
  row "mutation-baseline (TREND)" PASS "$(ls .prod/mutation/baseline-*.md | head -1)"
else row "mutation-baseline (TREND)" FAIL "no baseline artifact"; fi

# --- 7. scenarios matrix ----------------------------------------------------
if [[ -f .prod/failure-modes.md ]]; then
  # tested / N/A / blocked all anchored to the SECOND cell -- the status column
  # -- and matched case-insensitively, for the same reason. Only `blocked` was
  # fixed the first time round, which left its two neighbours matching the word
  # ANYWHERE on the line: the Totals table's own header
  # (`| Capability | Class | Tested | N/A | Blocked | Checklist size |`) counted
  # as an N/A row, so the probe reported N/A=16 while the matrix's own totals
  # said 15. `tested` came out right at 30 only because its alternation happened
  # to miss the header's capitalisation -- correct by luck. Fixing one of three
  # and leaving the others is how a gate ends up disagreeing with the very
  # document it scores.
  #
  # A third round on the same three lines, and the lesson is the same one: an
  # anchor that is exactly right for the shape you happened to look at.
  # Anchoring to the whole cell fixed the header-counts-as-a-row bug and then
  # rejected every REAL row, because the convention in this file is
  # `| timeout | tested (new) | ... |` -- a qualifier in parentheses after the
  # status word. Result: `tested=0`, and the row PASSED reporting it. So the
  # status word may be followed by an optional parenthetical, and nothing else.
  status_cell() { # status_cell <word-regex> -- count rows whose SECOND cell is that status
    grep -cE "^\|[^|]*\|[[:space:]]*\**${1}\**([[:space:]]*\([^)]*\))?[[:space:]]*\|" .prod/failure-modes.md || true
  }
  tested=$(status_cell '[Tt][Ee][Ss][Tt][Ee][Dd]')
  na=$(status_cell '[Nn]/?[Aa]')
  # Anchored to a whole STATUS CELL, not "the word appears anywhere on the
  # line". The substring form failed the build for any repo that added a
  # summary table to this file, because a header cell or a totals row
  # containing the word "blocked" counted as a blocked scenario. Note this is
  # Anchored to the SECOND cell -- the status column -- and case-INSENSITIVE.
  # Both halves are load-bearing and both were wrong. The old pattern matched
  # `blocked` in any cell of the row, so the summary table's own header
  # (`| Capability | Class | Tested | N/A | Blocked | ... |`) counted as a
  # blocked scenario; and it was case-SENSITIVE, so a row written
  # `| timeout | **BLOCKED** | ... |` -- the emphasis a human naturally reaches
  # for on the one row that matters -- was counted as zero. Measured in
  # marketdata: one genuinely blocked scenario (`Migrate` has no internal
  # timeout while its six siblings do), and the row reported `blocked=0` and
  # PASSED. A gate that reads only lower-case failure states is a gate that
  # passes whenever someone shouts.
  blocked=$(status_cell '[Bb][Ll][Oo][Cc][Kk][Ee][Dd]')
  if (( blocked > 0 )); then row "scenario-matrix" FAIL "$blocked checklist entries blocked (need production changes)"
  elif (( tested == 0 )); then
    # tested=0 is not a passing state, it is a broken parser. The previous
    # version printed exactly that and PASSED -- the failure mode this whole
    # standard exists to name, in the row that scores the scenario coverage.
    row "scenario-matrix" FAIL "tested=0 with N/A=$na -- a matrix whose every scenario is N/A means the status parser stopped matching, not that the work is done"
  else row "scenario-matrix" PASS "tested=$tested N/A=$na blocked=0"; fi
else row "scenario-matrix" FAIL "no .prod/failure-modes.md — denominator unknown"; fi

# --- 8. integration fidelity (a real-dependency lane exists AND runs) ------
# A real-dependency lane is one that talks to something OUTSIDE the process:
# a real socket, a container, or a live provider. The advisory `candidate` tag
# is NOT one — matching it was a false PASS in an earlier version of this probe.
real_tag=$(grep -rho 'go:build [a-z_]*' --include='*_test.go' . 2>/dev/null | awk '{print $2}' \
           | grep -vE '^(candidate|ignore)$' | sort -u | head -1)
live_gate=$(grep -rlE 'os\.Getenv\("[A-Z_]*LIVE[A-Z_]*"\)' --include='*_test.go' . 2>/dev/null | head -1)
if [[ -n "$real_tag" ]]; then
  # Scope the run to the packages that actually CONTAIN the tagged files, and
  # keep the output.
  #
  # This used to be `go test -tags=$real_tag ./... >/dev/null 2>&1`, which is
  # wrong twice. It ran the WHOLE repo under the tag, so any unrelated flake
  # anywhere failed this row -- and then reported "the lane did not run green",
  # blaming a lane that was fine. And it discarded the output, so the FAIL
  # carried no evidence at all: the one thing a finding must always do is name
  # the defect.
  real_pkgs=$(grep -rl "go:build $real_tag" --include='*_test.go' . 2>/dev/null \
              | xargs -n1 dirname 2>/dev/null | sort -u | sed 's|^|./|' | tr '\n' ' ')
  [[ -n "$real_pkgs" ]] || real_pkgs=./...
  # shellcheck disable=SC2086
  if rl_out=$(go test -tags="$real_tag" $real_pkgs -count=1 2>&1); then
    extra=""; [[ -n "$live_gate" ]] && extra=" + env-gated live lane"
    row "integration-real-lane" PASS "lane '-tags=$real_tag' runs green in $(wc -w <<<"$real_pkgs" | tr -d ' ') pkg(s)$extra"
  else
    row "integration-real-lane" FAIL "lane '-tags=$real_tag': $(grep -m1 -E '^--- FAIL|^FAIL|panic:' <<<"$rl_out" | cut -c1-120)"
  fi
elif [[ -n "$live_gate" ]]; then
  row "integration-real-lane" PASS "env-gated live lane only ($live_gate)"
else row "integration-real-lane" FAIL "every test is hermetic — no real-dependency lane"; fi

# --- 9. compatibility ------------------------------------------------------
# EXECUTED, not grepped, and matched on executable identifiers rather than
# prose.
#
# This row used to be `grep -rql "wire\|golden\|protoreflect\|unknown.field"`
# over every *_test.go. In marketdata 39 test files contain the word "wire" --
# in comments, in variable names, in the phrase "on the wire" -- so the row
# could not go red if every compatibility test in the repo were deleted and one
# comment survived. It certified a dimension the gap report presents as
# delivered, on the strength of a word.
#
# The markers below are all IDENTIFIERS that only appear in code that actually
# exercises the wire format: a protoreflect call, a golden-file comparison, an
# unknown-field round trip, a raw proto.Unmarshal. From the files carrying one,
# the test functions are extracted and RUN by name, and the row requires both a
# non-zero count and a green run -- the same shape replay-corpus and benchmarks
# already use in this file.
compat_files=$(grep -rl -E 'protoreflect\.|\.golden|UnknownFields|proto\.Unmarshal' --include='*_test.go' . 2>/dev/null || true)
if [[ -z "$compat_files" ]]; then
  row "compatibility" FAIL "no compatibility tests: nothing in the tree calls protoreflect, compares a golden, round-trips unknown fields, or unmarshals raw proto"
else
  compat_funcs=$(grep -ho -E '^func (Test[A-Za-z0-9_]+)' $compat_files 2>/dev/null | awk '{print $2}' | sort -u)
  compat_n=$(printf '%s\n' "$compat_funcs" | sed '/^$/d' | wc -l | tr -d ' ')
  compat_pkgs=$(printf '%s\n' $compat_files | xargs -n1 dirname 2>/dev/null | sort -u | sed 's|^|./|;s|^\./\./|./|')
  if (( compat_n == 0 )); then
    row "compatibility" FAIL "files carry compatibility markers but declare no Test function -- nothing to run"
  else
    compat_re=$(printf '%s\n' "$compat_funcs" | sed '/^$/d' | paste -sd'|' -)
    if compat_out=$(go test -count=1 -run "^(${compat_re})\$" $compat_pkgs 2>&1); then
      row "compatibility" PASS "$compat_n wire/contract test(s) RAN green: $(printf '%s' "$compat_re" | cut -c1-90)"
    else
      row "compatibility" FAIL "compatibility tests red: $(grep -m1 -E '^--- FAIL|^FAIL|panic:' <<<"$compat_out" | cut -c1-120)"
    fi
  fi
fi

# --- 10. performance: benchmarks exist, RUN, and have a baseline -----------
# "$nb benchmarks run" used to be a GREP of `func Benchmark` across every test
# file, while the run itself was untagged. Measured in clcsolutions/marketdata:
# 15 declared, all three benchmark files behind `//go:build candidate`, and
# ZERO compiled or executed -- the row printed "15 benchmarks run" for a
# command that ran none, and `go test`'s exit status was 0 because there was
# nothing to fail. The count now comes from the OUTPUT, the run carries the
# tags the benchmark files themselves declare, and the evidence names those
# tags so a performance dimension parked in an advisory lane is visible rather
# than implied.
mapfile -t bench_files < <(grep -rl 'func Benchmark' --include='*_test.go' . 2>/dev/null | grep -v '^\./\.git/')
if ((${#bench_files[@]})); then
  bench_declared=$(grep -rh 'func Benchmark' --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
  bench_tags=$(grep -h '^//go:build' "${bench_files[@]}" 2>/dev/null \
    | sed 's|^//go:build||' | tr -c 'A-Za-z0-9_' ' ' | tr ' ' '\n' \
    | sed '/^$/d' | grep -vx 'ignore' | sort -u | tr '\n' ',' | sed 's/,$//')
  bench_out=$(go test -run='^$' -bench=. -benchtime=10x ${bench_tags:+-tags="$bench_tags"} ./... 2>&1)
  bench_ran=$(grep -cE '^Benchmark[A-Za-z0-9_]+' <<<"$bench_out")
  bench_ran=${bench_ran:-0}
  base=$(ls benchmarks/baseline-*.txt 2>/dev/null | head -1)
  if (( bench_ran == 0 )); then
    row "benchmarks" FAIL "$bench_declared declared, ZERO executed${bench_tags:+ under -tags='$bench_tags'} — a benchmark that never runs is a file, not a measurement"
  elif [[ -z "$base" ]]; then
    row "benchmarks" FAIL "$bench_ran benchmark(s) ran but no baseline recorded"
  else
    row "benchmarks" PASS "$bench_ran of $bench_declared declared benchmark(s) executed${bench_tags:+ under -tags='$bench_tags'}; baseline $base"
  fi
else row "benchmarks" FAIL "no benchmarks"; fi

# --- 11. profiling (capture path AND live endpoint) ------------------------
#
# WHAT THIS ROW MEASURES, AND THE HALF IT DOES NOT.
#
# Both halves below are ON-DEMAND: a capture script somebody runs, and an
# endpoint somebody scrapes while the incident is still live. dimensions.md §8
# makes profiling the FOURTH observability signal and requires it CONTINUOUS
# in production -- always-on sampling shipped to a store with retention, so a
# profile of the process that was slow last Tuesday exists at all (Ren, Tune,
# Moseley, Shi, Rus, Hundt, "Google-Wide Profiling", IEEE Micro 30(4), 2010).
#
# This row cannot see that: continuous collection lives in a deployment's
# agent/sidecar/SDK configuration, not in the repo's Go source, so a grep
# here would be a keyword check standing in for a property -- the mistake
# this file has made four times. So the row keeps measuring what it can and
# the EVIDENCE STRING states the gap, rather than a PASS quietly implying a
# requirement it never checked.
prof_capture=$([[ -f benchmarks/profile.sh ]] && echo yes || echo no)
prof_live=$(grep -rql "net/http/pprof" --include='*.go' . 2>/dev/null && echo yes || echo no)
if [[ "$prof_capture" == yes && "$prof_live" == yes ]]; then
  row "profiling" PASS "capture script + env-gated live endpoint — the ON-DEMAND half only. Whether profiles are collected CONTINUOUSLY in production (dimensions.md §8) is not checkable from source and is NOT claimed by this row"
elif [[ "$prof_capture" == yes || "$prof_live" == yes ]]; then
  row "profiling" FAIL "only half present (capture=$prof_capture live=$prof_live)"
else row "profiling" FAIL "no profiling at all (claiming 'documented' is the known lie)"; fi

# --- 12. recovery / replay corpus -----------------------------------------
if ls regressions/*/events.json >/dev/null 2>&1; then
  n=$(ls -d regressions/*/ 2>/dev/null | wc -l | tr -d ' ')
  if go test ./... -run 'Replay|Regression' -count=1 >/dev/null 2>&1; then
    row "replay-corpus" PASS "$n fixtures, harness green"
  else row "replay-corpus" FAIL "$n fixtures but the harness did not run"; fi
else
  # NOT excusable by declining event_sourcing, which this row used to allow.
  # The two are different things: the event LOG is derived from whether the
  # workload is a fold over an ordered stream, while the CORPUS is fixtures
  # driven through the real decode->core->serve path asserting invariants at
  # every transition. That is worth having whether or not the fixtures came
  # from a durable log -- so a repo that declines event sourcing still owes
  # its regression corpus, and letting one excuse the other turned a
  # derivation into an escape hatch.
  row "replay-corpus" FAIL "no replay corpus -- required regardless of whether event sourcing applies (the LOG is derived, the CORPUS is not)"
fi

# implemented_test reads an OPTIONAL `implemented:` block from the spec:
#
#   implemented:
#     effect_journal_outbox: ./internal/adapter/out/store TestOutbox_SurvivesARestart
#
# i.e. a package and the test that PROVES the dimension. The probe then RUNS
# that test and requires it green. Same design as a ratification package's
# non_vacuity_check: the artifact names an executable check and the probe
# executes it, rather than the probe guessing from a keyword.
implemented_test() {
  awk -v key="$1" '
    /^implemented:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ "^" key ":") { sub("^" key ":[[:space:]]*", "", line); print line; exit }
    }
  ' "$SPEC" 2>/dev/null
}

# Three dimensions whose only non-FAIL path used to be a ratified DECLINE.
#
# effect_journal_outbox and backup_restore_test had NO implementation branch
# at all: a repo that genuinely built a durable outbox could either declare it
# declined -- a lie that turns the row NA -- or take a FAIL. The probe could
# not record the good outcome, which pressured every repo toward writing a
# false decline to get green. A gate whose output stops corresponding to
# reality is the defect this file exists to prevent.
#
# reconciliation had a branch, but it was `grep -rqi "reconcil"` -- a keyword
# search over the code under review, satisfied by a comment saying
# reconciliation is NOT implemented. It is kept as a fallback so existing
# repos do not go red, but the evidence string now says it was a keyword
# match, so the weakness is visible in the report instead of reading as proof.
# effect_journal_atomic joins this loop deliberately: it uses the same
# implemented:/declined machinery, so the only way to claim it is to name a
# test the probe then EXECUTES. A row that grepped for "outbox" or "atomic"
# would be this file's oldest mistake for the fourth time -- and it would be
# especially useless here, since the defect this checks for is present in code
# that says "outbox" everywhere. The proving test has a specific shape: crash
# between the state commit and the effect journal, recover, and assert the
# effect is still delivered.
#
# implemented_row runs the shared "the spec names a test and the probe EXECUTES
# it" check for one key, and emits a row under the given label. Every dimension
# added after scalability uses this rather than copying the loop, because the
# copy is where the keyword-grep habit creeps back in: this helper cannot be
# satisfied by a word appearing anywhere.
implemented_row() { # implemented_row <label> <spec-key> <extra-fail-hint>
  local label="$1" key="$2" hint="${3:-}"
  if declined "$key"; then row "$label" NA "ratified decline in $SPEC"; return; fi
  local spec_test; spec_test="$(implemented_test "$key")"
  if [[ -z "$spec_test" ]]; then
    row "$label" FAIL "not declined, and no implemented.$key in $SPEC naming the test that proves it${hint:+ -- $hint}"
    return
  fi
  local it_pkg="${spec_test%% *}" it_name="${spec_test##* }"
  if [[ -z "$it_pkg" || "$it_pkg" == "$it_name" ]]; then
    row "$label" FAIL "spec's implemented.$key must be '<package> <TestName>', got '$spec_test'"
    return
  fi
  # `go test -list` prints NOTHING when the package fails to build, which is
  # indistinguishable from "the test is gone" unless you look at why. The first
  # version of this helper did not, and reported a compile error somewhere else
  # in the repo as "the evidence has decayed" -- blaming the spec, which is
  # correct-sounding, actionable, and wrong. Same class as the coverage row that
  # rendered an evidence-free FAIL: a gate that misattributes a failure sends
  # someone to edit the one file that was fine.
  local list_out list_rc
  list_out="$(go test "$it_pkg" -list "^${it_name}$" 2>&1)"; list_rc=$?
  if (( list_rc != 0 )); then
    row "$label" FAIL "cannot evaluate $it_name: $it_pkg does not build -- this is a BUILD failure, not a decayed spec: $(grep -m1 -oE '[^ ]+\.go:[0-9]+:[0-9]+: .*' <<<"$list_out" | cut -c1-90)"
  elif ! grep -qx "$it_name" <<<"$list_out"; then
    row "$label" FAIL "spec names $it_name in $it_pkg but no such test exists -- the evidence has decayed"
  elif go test "$it_pkg" -run "^${it_name}$" -count=1 >/dev/null 2>&1; then
    row "$label" PASS "proven by $it_name ($it_pkg), executed this run"
  else
    row "$label" FAIL "$it_name ($it_pkg) is RED -- the dimension it proves is not implemented"
  fi
}

for k in effect_journal_outbox effect_journal_atomic reconciliation backup_restore_test; do
  if [[ -n "$(implemented_test "$k")" ]] || declined "$k"; then
    implemented_row "$k" "$k"
    continue
  fi

  case "$k" in
    reconciliation)
      grep -rqi "reconcil" --include='*.go' . \
        && row "$k" PASS "keyword match only (no implemented.$k in $SPEC naming a test to execute)" \
        || row "$k" FAIL "no reconciliation and no ratified decline";;
    *) row "$k" FAIL "not implemented, not declined, and no implemented.$k in $SPEC naming the test that proves it";;
  esac
done

# --- 12b. scalability (dimension 12) --------------------------------------
#
# REQUIRED BY DEFAULT, every tier: a system must scale vertically AND
# horizontally unless the spec ratifies a decline saying why not.
#
# The three testable sub-dimensions reuse implemented_test above, so the probe
# EXECUTES the named test rather than guessing. A row here that grepped for
# "snapshot" or "compact" would repeat this file's own worst habit -- the
# `grep -qi "reconcil"` satisfied by a comment saying reconciliation is absent,
# and the `mutation` keyword search satisfied by typing the word. Both shipped.
for k in bounded_boot bounded_storage egress_backpressure; do
  implemented_row "scalability:$k" "$k"
done

# spec_field reads one scalar from a named top-level block of the spec:
#
#   spec_field scalability partition_key   ->  the value, or empty
#
# Declarations, not tests: no test can tell you what a workload's partition key
# SHOULD be, or how long history ought to be kept, and pretending otherwise
# would be a worse gate than an honest declaration check. What a declaration
# check CAN do is refuse the placeholder someone types to get green, which is
# what every caller below does.
spec_field() {
  awk -v block="$1" -v key="$2" '
    function txt(  l) { l=$0; sub(/^[[:space:]]+/, "", l); return l }
    $0 ~ "^" block ":" { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      ind = match($0, /[^ \t]/) - 1
      # INSIDE A BLOCK BODY: consume it whatever key opened it.
      if (inblk) {
        if ($0 ~ /^[[:space:]]*$/) next
        if (ind > blkind) { if (want) body = (body == "" ? txt() : body " " txt()); next }
        inblk = 0
        if (want) { print body; exit }
        # not the requested key: this line ended the block and is still
        # structure, so fall through and examine it below.
      }
      line = txt()
      # SAME OPENER AS check-registries.sh, and it has to be: this function
      # walks a block body as keys for exactly the same reason, so a narrower
      # class here reopens the fail-open this file just closed next door. Three defects
      # lived in the previous line, all of them already fixed over there:
      #   - the key class was an allowlist, so `ops evidence: |`,
      #     `"ops evidence": |` and `"a:b": |` were not recognised and their
      #     prose was read as structure;
      #   - `[[:space:]]*$` refused a trailing comment, so `key: > # note`
      #     opened nothing and its body was walked;
      #   - the indicator range `([0-9][+-]?|[+-][0-9]?)` accepted only ONE
      #     digit, so `|22`, `|22-` and `|-22` were misread.
      # Permissive is the fail-CLOSED direction here: an unrecognised header is
      # not skipped, it is walked.
      if (line ~ /^.*:[[:space:]]*[|>]([0-9]+[+-]?|[+-][0-9]*)?[[:space:]]*(#.*)?$/) {
        blkind = ind; inblk = 1; body = ""; want = (line ~ "^" key ":")
        next
      }
      if (line ~ "^" key ":") { sub("^" key ":[[:space:]]*", "", line); gsub(/^"|"$/, "", line); print line; exit }
    }
    END { if (inblk && want) print body }
  ' "$SPEC" 2>/dev/null
}

# scalability_field is spec_field pinned to the scalability block, kept so the
# rows below read the way they did when they were written.
scalability_field() { spec_field scalability "$1"; }

# placeholder_value reports whether a declaration is one of the words people
# type to make a required field go green without answering it. Shared by every
# declaration row, because otherwise each grows its own drifting list.
placeholder_value() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    ""|todo|tbd|none|n/a|na|null|"-"|unknown|fixme|xxx) return 0 ;;
    *) return 1 ;;
  esac
}

# driven_symbol reads one entry from the spec's `driven:` block:
#
#   driven_symbol durable_outbox   ->  store.OpenDurable
#
# See the driven-mechanisms row for why this block exists and why it is
# checked against a LINKED BINARY rather than against source.
driven_symbol() {
  awk -v key="$1" '
    /^driven:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ "^" key ":") { sub("^" key ":[[:space:]]*", "", line); gsub(/^"|"$/, "", line); print line; exit }
    }
  ' "$SPEC" 2>/dev/null
}

# driven_keys lists every key declared under `driven:`.
driven_keys() {
  awk '
    /^driven:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock && /^[[:space:]]+[a-z_]+:/ {
      line=$0; sub(/^[[:space:]]+/, "", line); sub(/:.*$/, "", line); print line
    }
  ' "$SPEC" 2>/dev/null
}


# A presence check is weak, so both fields below are constrained rather than
# free text. partition_key rejects the placeholders someone types to get green,
# and the honest "there is no key" answer is routed to the DECLINE path, which
# costs a written reason in out_of_scope. durability_trade takes a closed
# vocabulary: a fixed set is far harder to satisfy accidentally than prose.
if declined "partition_key"; then
  row "scalability:partition_key" NA "single-writer ratified as a decline in $SPEC"
else
  pk="$(scalability_field partition_key)"
  pk_norm="$(printf '%s' "$pk" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  case "$pk_norm" in
    ""|todo|tbd|none|n/a|na|null|"-"|unknown|fixme)
      row "scalability:partition_key" FAIL "scalability.partition_key in $SPEC is '${pk:-<absent>}' -- name the key, or ratify a decline explaining why the workload is genuinely single-writer";;
    *) row "scalability:partition_key" PASS "partitions on '$pk'";;
  esac
fi

dt="$(scalability_field durability_trade)"
dt_norm="$(printf '%s' "$dt" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
case "$dt_norm" in
  fsync_per_event|group_commit|no_durable_writes)
    row "scalability:durability_trade" PASS "declared: $dt_norm";;
  *)
    row "scalability:durability_trade" FAIL "scalability.durability_trade in $SPEC is '${dt:-<absent>}' -- must be one of fsync_per_event | group_commit | no_durable_writes, so the hot path's loss window is a stated choice rather than an accident";;
esac

# --- 12c. bounded auto-recovery (dimension 13) ----------------------------
#
# Dimension 8 asks whether a failure is VISIBLE. This asks whether the system
# comes BACK. Both defects that motivated it were counted, logged and panelled,
# and neither ever recovered without a human: an undecodable message wedged a
# consumer forever because the cursor could not advance past it, and an
# upstream that restarted its own history left the consumer polling a position
# that no longer existed, receiving nothing, silently, indefinitely.
#
# The proving test has a specific shape and it is worth stating, because a test
# that merely asserts "the error is counted" would satisfy a lazier reading:
# INDUCE the failure, then assert the system returns to normal operation with
# no intervention. A failure you can provoke is a recovery you can time.
implemented_row "auto-recovery:self_recovery" self_recovery \
  "the test must INDUCE a detected failure and prove the system returns unaided, not merely that the failure is counted"

# recovery_bound is a declaration: no test can tell you what recovery latency
# this workload is willing to tolerate. "manual" is an HONEST answer for a mode
# that genuinely needs a human, and it routes to the decline path so that
# answer costs a written reason instead of a shrug.
if declined "recovery_bound"; then
  row "auto-recovery:recovery_bound" NA "manual intervention ratified as a decline in $SPEC"
else
  rb="$(spec_field auto_recovery recovery_bound)"
  rb_norm="$(printf '%s' "$rb" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  if placeholder_value "$rb"; then
    row "auto-recovery:recovery_bound" FAIL "auto_recovery.recovery_bound in $SPEC is '${rb:-<absent>}' -- state the maximum time to self-recovery"
  elif [[ "$rb_norm" == "manual" || "$rb_norm" == "unbounded" || "$rb_norm" == "never" ]]; then
    row "auto-recovery:recovery_bound" FAIL "auto_recovery.recovery_bound is '$rb' -- a mode that never returns unaided is a ratified DECLINE with its reason, not a bound"
  elif [[ "$rb_norm" =~ ^[0-9]+(ms|s|m|h)$ ]]; then
    row "auto-recovery:recovery_bound" PASS "returns unaided within $rb"
  else
    row "auto-recovery:recovery_bound" FAIL "auto_recovery.recovery_bound is '$rb' -- must be a duration like 30s / 5m / 2h, so the bound is checkable rather than adjectival"
  fi
fi

# --- 12d. the published contract (dimension 14) ---------------------------
#
# The asymmetry this exists for, observed in a service built from this
# template: it versioned the formats only IT read with real rigour --
# schema_version per record, write-one-read-many, golden fixtures per version,
# loud refusal on unknown -- while the payload it PUBLISHED to other people's
# consumers carried fourteen JSON fields and no version at all.
#
# That is backwards from where the cost falls. You can migrate your own log
# whenever you like, because you are the only reader. You cannot migrate
# someone else's consumer. A published event is an API.
#
# Kept separate from the `compatibility` row above on purpose: that row is
# satisfied by any wire or golden test, including one over a format nobody
# outside this repo parses. The audience is what makes this expensive, so the
# audience is what it keys on.
if declined "published_contract"; then
  row "published-contract:versioned"    NA "nothing published to a foreign consumer; declined in $SPEC"
  row "published-contract:shape_pinned" NA "nothing published to a foreign consumer; declined in $SPEC"
  row "published-contract:policy"       NA "nothing published to a foreign consumer; declined in $SPEC"
else
  implemented_row "published-contract:versioned" published_contract_versioned \
    "the test must assert the emitted payload carries a version a consumer can branch on"
  implemented_row "published-contract:shape_pinned" published_contract_shape \
    "the test must FAIL when the emitted shape changes -- a golden over what you publish, not over what you store"

  cp_="$(spec_field published_contract compatibility_policy)"
  cp_norm="$(printf '%s' "$cp_" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  case "$cp_norm" in
    expand_contract|versioned_envelope)
      row "published-contract:policy" PASS "declared: $cp_norm";;
    *)
      row "published-contract:policy" FAIL "published_contract.compatibility_policy in $SPEC is '${cp_:-<absent>}' -- must be expand_contract | versioned_envelope, or decline published_contract if nothing leaves this repo";;
  esac
fi

# --- 12e. data lifecycle (dimension 15) -----------------------------------
#
# This framework pushes services toward event sourcing, so it creates this
# problem and owes an answer to it. "Delete this subject's data" is genuinely
# hard against an immutable append-only log, and harder once a snapshot has
# folded that data in -- deleting the log entry leaves the snapshot holding it.
#
# retention_policy is NOT bounded_storage. That row asks whether SOMETHING
# prunes the store; this one asks how long history is deliberately kept, which
# is a different question with a different owner: one is an engineering bound,
# the other is a policy commitment.
if declined "retention_policy"; then
  row "data-lifecycle:retention" NA "ratified decline in $SPEC"
else
  rp="$(spec_field data_lifecycle retention_policy)"
  if placeholder_value "$rp"; then
    row "data-lifecycle:retention" FAIL "data_lifecycle.retention_policy in $SPEC is '${rp:-<absent>}' -- state how long history is kept and what bounds it"
  else
    row "data-lifecycle:retention" PASS "retention: $rp"
  fi
fi

dm="$(spec_field data_lifecycle deletion_mechanism)"
dm_norm="$(printf '%s' "$dm" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
case "$dm_norm" in
  crypto_shredding|tombstone_rebuild|log_expiry)
    # A real mechanism is claimed, so it owes a test that proves a deletion
    # request actually removes the data -- snapshots included.
    row "data-lifecycle:deletion_mechanism" PASS "declared: $dm_norm"
    implemented_row "data-lifecycle:subject_deletion" subject_deletion \
      "the test must prove a deletion request removes the data from the log AND from any snapshot that already folded it in";;
  no_subject_data)
    row "data-lifecycle:deletion_mechanism" PASS "declared: no_subject_data (no deletable subject exists)"
    row "data-lifecycle:subject_deletion" NA "no subject data to delete";;
  *)
    row "data-lifecycle:deletion_mechanism" FAIL "data_lifecycle.deletion_mechanism in $SPEC is '${dm:-<absent>}' -- must be crypto_shredding | tombstone_rebuild | log_expiry | no_subject_data; an immutable log makes this a design-time choice, not a later one"
    row "data-lifecycle:subject_deletion" FAIL "no deletion mechanism declared, so nothing can prove deletion works";;
esac

# --- 13. observability: contract CHECKED, tracer WIRED --------------------
# The row's CLAIM is "a test compares emitted signals to the manifest", so the
# check has to be about a test READING the manifest and PASSING -- not about a
# string. It used to fire on the literal "emitted-metrics" or "spans.yaml"
# appearing anywhere in any *_test.go, which a comment satisfies; a repo could
# delete the comparison, keep the sentence describing it, and stay green while
# the manifest went back to being documentation. Now: the manifest must exist,
# some test must both name it AND actually read a file, and that test package
# must run green.
mapfile -t obs_manifests < <(find . -path ./.git -prune -o \
  \( -name 'spans.yaml' -o -name 'emitted-metrics.*' \) -print 2>/dev/null)
if ((${#obs_manifests[@]} == 0)); then
  row "observability-contract-checked" FAIL "no spans.yaml / emitted-metrics.* manifest exists at all"
else
  obs_readers=""
  for m in "${obs_manifests[@]}"; do
    base=$(basename "$m")
    while IFS= read -r tf; do
      # Belt and braces on the filename. `--include` is not honoured
      # identically by every grep on every machine -- ugrep matched
      # scripts/verify-standard.sh here for an --include='*_test.go' search --
      # and one non-Go path in the list makes the `go test` below fail with
      # "no Go files", turning a green contract into a red row for a reason
      # that has nothing to do with observability.
      [[ "$tf" == *_test.go ]] || continue
      grep -qE 'os\.ReadFile|os\.Open|embed\.FS|//go:embed|ioutil\.ReadFile' "$tf" 2>/dev/null || continue
      d=$(dirname "$tf")
      # And it must be a real Go package, asked of the toolchain rather than
      # inferred from the path.
      go list "$d" >/dev/null 2>&1 && obs_readers+="$d"$'\n'
    done < <(grep -rl -- "$base" --include='*_test.go' . 2>/dev/null)
  done
  obs_pkgs=$(printf '%s' "$obs_readers" | sort -u | sed '/^$/d')
  if [[ -z "$obs_pkgs" ]]; then
    row "observability-contract-checked" FAIL "${#obs_manifests[@]} manifest(s) exist but no test READS one — naming it in a comment is not a check"
  elif obs_out=$(go test -count=1 $(printf './%s ' $(printf '%s' "$obs_pkgs" | sed 's|^\./||')) 2>&1); then
    row "observability-contract-checked" PASS "$(grep -c . <<<"$obs_pkgs") package(s) read and verify ${#obs_manifests[@]} manifest(s), green"
  else
    # Prefer a file:line diagnostic, fall back to the first real error line --
    # "see go test output" is not evidence, and this row printed exactly that
    # while the actual cause was a non-package directory in the list.
    obs_why=$(grep -m1 -E '^[^[:space:]]+\.go:[0-9]+:' <<<"$obs_out" \
      || grep -m1 -E 'no Go files|cannot find|^FAIL|build failed' <<<"$obs_out" \
      || printf '%s' "$(tail -n1 <<<"$obs_out")")
    row "observability-contract-checked" FAIL "the test(s) that read the manifest are RED: ${obs_why:-unknown}"
  fi
fi

# Logs correlate, or they are a second system nobody can join to the first.
#
# In Go, `logger.Info(...)` DROPS the trace context: only the *Context variants
# read it. A service can be fully traced, exporting to Tempo, with dashboards
# and alerts, and still have zero correlated log lines -- and nothing fails,
# because every individual piece works. The ratio is the only tell.
#
# Conditional on the repo actually using slog: a repo on another logger, or on
# none, must not fail a row about slog. An absent denominator is NA, never PASS
# -- "0 of 0 call sites are wrong" is the vacuous pass this framework exists to
# refuse.
if grep -rql 'log/slog' --include='*.go' . 2>/dev/null; then
  # The two counts are DISJOINT: `\.Info\(` requires the paren immediately
  # after the name, so it does not match `.InfoContext(`. An earlier version
  # of this row subtracted one from the other "to remove the overlap", which
  # drove the plain count negative on a fully-compliant repo and reported NA
  # -- a clean repo scoring as unmeasurable. Verified: `echo '.InfoContext('
  # | grep -cE '\.(Info)\('` is 0.
  #
  # --exclude, NOT a piped `grep -v '_test.go'`. With -o the output is the
  # match alone with no filename, so a downstream filename filter matches
  # nothing and silently counts every test file. That mistake made this row
  # report 80 call sites where the repo has 35, and flipped the handler row
  # below from FAIL to PASS on a handler that only a test constructs.
  # `\(([^)]|$)` -- NOT a bare `\(`. `err.Error()` is the error interface's
  # own method, not a log call, and a bare paren counts every one of them: in
  # the repo this row was built against, 7 of 15 `.Error(` hits were
  # `err.Error()`. That inflated the denominator and made a healthy level
  # distribution (7 error logs, 14 info, 11 warn) read as "more ERROR than
  # everything else combined". The discriminator is arguments: a log call
  # always has some, `err.Error()` never does. The `|$` arm keeps a call whose
  # arguments start on the NEXT line from being dropped.
  # Comment lines are dropped before counting. A repo that documents this very
  # rule -- "logger.Info(...) discards the trace context" -- would otherwise
  # have its own prose counted as a violation of it. Observed: a repo at 35 of
  # 35 compliant reported "35 of 36", the phantom being one sentence in a
  # comment. Harmless at that ratio, and a wrong FAIL at a closer one.
  # (A trailing comment on a code line still counts; that is rare enough to
  # accept, and erring toward counting is the safe direction for this row.)
  slog_plain=$(grep -rhE '\.(Info|Warn|Error|Debug)\(([^)]|$)' --include='*.go' --exclude='*_test.go' . 2>/dev/null | grep -vE '^[[:space:]]*//' | grep -oE '\.(Info|Warn|Error|Debug)\(([^)]|$)' | wc -l | tr -d ' ')
  slog_ctx=$(grep -rhE '\.(Info|Warn|Error|Debug)Context\(' --include='*.go' --exclude='*_test.go' . 2>/dev/null | grep -vE '^[[:space:]]*//' | grep -oE '\.(Info|Warn|Error|Debug)Context\(' | wc -l | tr -d ' ')
  if (( slog_plain + slog_ctx == 0 )); then
    row "observability:logs_correlate" NA "slog is imported but no log call sites found"
  elif (( slog_ctx == 0 )); then
    row "observability:logs_correlate" FAIL "$slog_plain log call site(s), NONE using the *Context variants -- the trace context is dropped, so no log line can be joined to its span no matter what the exporter is configured to do"
  elif (( slog_plain > slog_ctx )); then
    row "observability:logs_correlate" FAIL "$slog_plain of $(( slog_plain + slog_ctx )) log call sites drop the trace context (only $slog_ctx use *Context) -- partial correlation is worse than none, because the lines that DO correlate make the gap invisible"
  else
    row "observability:logs_correlate" PASS "$slog_ctx of $(( slog_plain + slog_ctx )) log call sites carry the trace context"
  fi

  # A structured handler must actually be INSTALLED. slog.Default() is a text
  # handler writing to stderr; a repo can log diligently for months and emit
  # nothing a log store can parse into fields.
  if grep -rqE 'slog\.(New(JSON|Text)Handler|NewMultiHandler|SetDefault)' --include='*.go' --exclude='*_test.go' . 2>/dev/null; then
    row "observability:log_handler_installed" PASS "a slog handler is constructed, not left at the default"
  else
    row "observability:log_handler_installed" FAIL "no slog handler is constructed anywhere -- slog.Default() emits unstructured text to stderr, so every structured field is lost before it reaches a log store"
  fi
fi

# THE probe that catches the no-op-port trap: wiring lives in the entrypoints
# Look for the INJECTION SITE, not the identifier.
#
# This row used to match "Tracer|tracer|SpanFunc" anywhere under cmd/ and report
# "tracer injected". A tracer that is constructed and thrown away -- literally
# `tracer := New(...)` followed by `_ = tracer` -- matches that grep, compiles,
# and leaves every package-level span test green, because those tests build
# their own recording tracer and never touch cmd/. Demonstrated by removing
# every real SetTracer/interceptor call from a working service: the build stayed
# green, the whole test suite stayed green, and this row still said PASS.
#
# So the row that exists to catch "instrumented but never wired" was itself
# fooled by "constructed but never wired". Requiring a call site where the
# tracer is PASSED or ASSIGNED closes the demonstrated hole. It is still an
# existence check and cannot prove the wiring reaches production -- only a
# contract test exercising the entrypoint can -- and the evidence now says so
# instead of claiming "injected".
# --include='*.go' --exclude='*_test.go': a contract test living under cmd/ is
# GOOD -- it is the only thing that can prove the wiring end to end -- but it is
# not the wiring. Counting it here let a repo pass with every real injection
# commented out and only the test's own call sites remaining, which is how the
# first attempt at tightening this row was still fooled.
#
# DISTRIBUTED TRACING IS CONDITIONAL, and this row used to pretend otherwise.
# A queue consumer, a cron batch or a daemon with no inbound request boundary
# has nothing to join a trace TO: it can only satisfy a universal requirement
# by emitting root spans nothing will ever parent, which is precisely the
# 3132-traces-of-one-span failure the next row exists to catch, reached on
# purpose. So a ratified `distributed_tracing` decline turns this row NA --
# see dimensions.md §8 and mechanism-derivation.md §8, where the verdict is
# DERIVED from repo signals rather than asked.
#
# But the decline is not free, because an unexamined decline is how every
# other requirement in this framework gets escaped. The derivation's strongest
# signal is mechanically checkable: routes registered for paths that are not
# the operational surface. If the repo has any, the decline is CONTRADICTED by
# the code and this row FAILs rather than going quietly NA.
#
# The check is deliberately one-directional and the evidence says so. Presence
# of a non-operational route disproves the decline. ABSENCE proves nothing --
# routes built from config, a gateway the repo cannot see, or a protocol
# nobody greps for would all be missed -- so the NA states that it is a
# ratified decline the probe could not contradict, never that headlessness was
# verified.
#
# The pattern requires a "/-prefixed literal IN THE CALL (or a gRPC service
# registration), not a bare `.Handle(`: `errHandler.Handle(err)` is an
# ordinary method call, and a row that reds a correctly-declined headless
# service is a row somebody switches off -- the same false-positive lesson
# the mechanisms-driven row learned about inlining.
inbound_route_sites() {
  grep -rnE '\.(Handle|HandleFunc|GET|POST|PUT|PATCH|DELETE|Any|Route)\([^)]*"/|Register[A-Za-z0-9_]*Server\(' \
    --include='*.go' --exclude='*_test.go' cmd/ internal/ 2>/dev/null \
    | grep -vE 'healthhttp|pprofhttp|"/healthz|"/readyz|"/livez|"/startupz|"/metrics|"/debug/pprof'
}
tracer_sites=$(grep -rn --include='*.go' --exclude='*_test.go' \
  "SetTracer(\|WithTracer(\|Tracer:\|Interceptor(.*[Tt]racer\|[Tt]racer)" cmd/ 2>/dev/null | wc -l | tr -d ' ')
if declined "distributed_tracing"; then
  n_inbound=$(inbound_route_sites | wc -l | tr -d ' ')
  if (( n_inbound > 0 )); then
    row "tracing-wired-in-prod" FAIL "$SPEC declines distributed_tracing, but the code registers $n_inbound route(s) outside the health/metrics/pprof surface — e.g. $(inbound_route_sites | head -1 | cut -c1-120). A decline of fact that the fact contradicts is the escape this framework refuses; re-derive per mechanism-derivation.md §8 or narrow the decline"
  else
    row "tracing-wired-in-prod" NA "ratified decline in $SPEC and the probe found no route registered outside the health/metrics/pprof surface to contradict it — this is a decline it could not disprove, NOT a verification that work never arrives with a caller's context. Correlation ids and EGRESS injection are still owed; only the inbound extraction half is declined"
  fi
elif [[ "${tracer_sites:-0}" -gt 0 ]]; then
  # The evidence string says what was OBSERVED and what it does not prove.
  #
  # Three attempts at this row were fooled in turn: matching the identifier
  # anywhere (a discarded `_ = tracer` passes), counting call sites (a contract
  # test's own calls pass), and excluding tests (a helper function that is
  # defined but never called passes). A grep can establish that wiring code
  # EXISTS; it cannot establish that it RUNS. Claiming "injected" was the defect
  # -- the row asserted more than it measured, which is the same failure it was
  # written to catch one level down.
  row "tracing-wired-in-prod" PASS "$tracer_sites tracer call-site(s) in non-test cmd/ code — existence only; the mechanisms-driven row proves reachability properly, and this one is kept as the earlier, weaker signal"
elif grep -rql "Tracer\|tracer\|SpanFunc" cmd/ 2>/dev/null; then
  row "tracing-wired-in-prod" FAIL "cmd/ names a tracer but never passes or assigns it — constructed and discarded is a no-op in production"
else
  grep -rql "StartSpan" --include='*.go' internal/ 2>/dev/null \
    && row "tracing-wired-in-prod" FAIL "spans instrumented but NO tracer in cmd/ — no-op in production" \
    || row "tracing-wired-in-prod" FAIL "no tracing at all"
fi

# A span is not a trace. Spans that cannot be PARENTED are 3132 traces of one
# span each, and every existing check passes on them.
#
# This was measured, not imagined. A repo with a correctly wired tracer, spans
# reaching the backend with full fidelity, RecordError firing in production on
# exactly the declared condition, and a green contract test, had:
#
#   tempo_distributor_spans_received_total  3132
#   tempo_ingester_traces_created_total     3132
#
# One trace created per span received, process-wide. Nothing was joinable to
# anything. A traceparent sent with a real request produced HTTP 404 for that
# trace id -- the header was silently dropped.
#
# The tracing-wired row cannot see this: the tracer IS wired and IS reachable,
# so it passes. mechanisms-driven cannot see it either, for the same reason.
# The defect is SEMANTIC -- the same shape as a lag metric derived from work
# done, which is correct only while nothing is wrong.
#
# What is mechanically checkable is the precondition: a service that starts
# spans and also talks to anything else needs a propagator installed and
# context injected on the way out, or a trace can never cross a process
# boundary. Absence of all of it is proof; presence is only a signal, so the
# PASS says so rather than claiming the traces are actually joined.
# Span detection must cover BOTH shapes: a house abstraction named StartSpan,
# and the raw OTel SDK's `tracer.Start(...)`. Matching only the first skipped
# the whole row -- silently -- for any repo using the SDK directly, which is
# the more common case. Caught by testing the row against a scratch module
# that used the SDK and got no output at all.
#
# DELIBERATELY NOT gated on the `distributed_tracing` decline above, and the
# asymmetry is the point. That decline is about the INBOUND extraction half --
# whether work arrives carrying a caller's context. EGRESS injection is owed
# by anything that makes an outbound call, headless or not: a batch job that
# writes to another system and drops the context truncates the trace of
# everything downstream of it. See mechanism-derivation.md §8's three-part
# table, where only the middle part is derived.
if grep -rqlE 'StartSpan|otel\.Tracer\(|TracerProvider|trace\.Tracer' \
     --include='*.go' --exclude='*_test.go' . 2>/dev/null; then
  egress=$(grep -rlE 'http\.NewRequest|http\.Client|\.Publish\(|PublishMsg\(|grpc\.Dial|NewClient\(' \
            --include='*.go' --exclude='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
  prop=$(grep -rlE 'SetTextMapPropagator|propagation\.|otelhttp|otelgrpc|traceparent|\.Inject\(|\.Extract\(' \
            --include='*.go' --exclude='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
  if (( egress == 0 )); then
    row "observability:trace_propagation" NA "spans are emitted but this service makes no outbound calls -- nothing to propagate to"
  elif (( prop == 0 )); then
    row "observability:trace_propagation" FAIL "spans are emitted and $egress file(s) make outbound calls, but NOTHING installs a propagator or injects trace context -- every span is a root, so the backend stores one trace per span and no request can be followed across a boundary"
  else
    row "observability:trace_propagation" PASS "$prop file(s) carry propagation machinery alongside $egress egress site(s) -- present, which is necessary; that traces are actually PARENTED is provable only by a test that asserts a child span's parent, or by reading the backend"
  fi
fi

# --- 13b. mechanisms are DRIVEN, not merely present ------------------------
#
# The strongest pattern this framework has found, and the one it kept missing.
# Four separate times, in a repo passing every other gate, a mechanism was
# fully implemented, unit-tested green, and CALLED BY NOTHING:
#
#   * a tracer instrumented with a passing span-contract test, never
#     constructed in cmd/ -- every span went nowhere;
#   * operational counters implemented and tested, never wired into the
#     metrics surface -- the series read 0 in production while the underlying
#     value climbed, so a derived lag went NEGATIVE: a healthy-looking
#     impossible number rather than a crash;
#   * a durable outbox constructor, tested, absent from the composition root,
#     which wired the in-memory form instead;
#   * an outbox Reconcile with passing tests and no caller, so a journaled
#     entry whose sink was down stayed pending for the life of the process.
#
# A mechanism nothing calls is indistinguishable from one that does not exist
# -- except that it passes its own tests, so the suite reports it as covered.
# That makes it WORSE than absent.
#
# HOW THIS IS PROBED, and why it is not another keyword grep. Every previous
# attempt at this class of check read SOURCE, and source cannot answer it: a
# grep for the constructor's name matches a comment, a discarded assignment, a
# helper that is itself never called, and the mechanism's own tests. This row
# reads the LINKED BINARY instead. Go's linker eliminates code unreachable
# from main, so a symbol's PRESENCE in the shipped artifact is evidence that
# production reaches it, and its absence is proof that nothing does.
#
# Verified empirically before this row was written: on the template,
# `store.OpenDurable` resolved to 1 symbol while wired and 0 after the call
# site was replaced with the in-memory constructor (the exact shape of defect
# three), and `Outbox.Reconcile` -- which nothing calls -- was already absent.
# A unit test cannot satisfy this check, because `go test` links a different
# binary that this row never inspects.
#
# THAT SECOND MEASUREMENT NO LONGER HOLDS, and the correction matters more
# than the original claim. The template later converted *Outbox to an
# interface (healthhttp.OutboxHealth), and Go's linker retains the ENTIRE
# METHOD SET of a type that reaches an interface -- so `Outbox.Reconcile`
# became present in the binary with still no caller, and this row went GREEN
# on a template whose reconcile loop did not exist. Measured on that binary:
#
#   1002fe8f0 T ….store.(*Outbox).Reconcile      (present, uncalled)
#
# So the two halves of this row are NOT symmetric, and the asymmetry is the
# thing to remember:
#
#   ABSENCE is still proof. Nothing reaches it.
#   PRESENCE is proof only for a symbol the linker COULD have eliminated.
#
# The precise rule, measured after a first draft of this comment overstated it:
# the linker retains the methods an INTERFACE REQUIRES, not every method a type
# has. So a method is weak evidence only when it sits in the method set of some
# interface its receiver reaches -- `Outbox.Reconcile` did, and stayed present
# with no caller at all; `(*rederivableSet).canRederive` did not, and vanished
# the moment its call site went away, making it honest evidence after all.
#
# This row cannot tell those apart without type information it does not have,
# so it flags EVERY method form as weak. That is the right conservative
# default, and it will sometimes be unfair to a declaration that is fine.
# Naming a package-level function removes the question entirely.
#
# Therefore: DECLARE THE CALLER, NOT THE CALLEE. Name the loop function that
# drives the mechanism (`main.reconcileLoop`), which belongs to no interface
# and is eliminated the moment its goroutine is deleted, rather than the
# method it calls. The row below flags a declared symbol in method form for
# exactly this reason.
#
# The first draft of this row also reported the template's TRACER as unwired,
# which was wrong: the compiler had inlined the constructor. See the build
# flags below. A row that cries wolf is a row somebody disables, so the false
# positive mattered more than the true ones.
#
# THE LIMIT, stated because a gate that overclaims is the defect this file
# exists to catch: the linker retains every method of an interface a program
# actually uses, since dynamic dispatch could reach any of them. So a method
# that is never called but belongs to a used interface WILL survive and this
# row will pass it. Plain functions and methods outside any used interface are
# eliminated precisely. That covers all four defects above; it is not a
# universal reachability proof, and it is not claimed as one.
if [[ -z "$(driven_keys)" ]]; then
  row "mechanisms-driven" FAIL "no driven: block in $SPEC -- every mechanism the service declares must name the symbol that proves production reaches it, or nothing distinguishes an implemented mechanism from a dead one"
else
  # A DIRECTORY, not a file. `go build -o <file> ./cmd/...` fails outright with
  # "cannot write multiple packages to non-directory" the moment a repo has more
  # than one cmd/ binary -- which is most of them. The row then reported the
  # wiring as unprovable for a reason that had nothing to do with the wiring,
  # and it did so in EVERY multi-binary repo, including both repos this standard
  # was developed against. Building into a directory and reading every binary in
  # it is what the row always meant.
  driven_bin="${TMPDIR:-/tmp}/prod-driven-$$"
  mkdir -p "$driven_bin"
  # Two build flags, both load-bearing.
  #
  # No -s/-w: this row needs the symbol table, which is exactly what those
  # strip.
  #
  # -gcflags=all=-l disables INLINING, and without it this row reports false
  # positives that would get it switched off within a week. A small function
  # that production really does call can be inlined into its caller, and an
  # inlined symbol is absent from the table in exactly the same way an
  # eliminated one is -- nm cannot tell you which happened.
  #
  # RE-MEASURED 2026-08-20 on the current template, because the original
  # citation named a symbol that has since been renamed and a second one whose
  # "no caller" half stopped being true. A stale measurement in a comment is
  # the same defect as a stale line number in a doc: it still LOOKS like
  # evidence.
  #
  #   observability.InstallPropagation   inlining ON: 0 symbols   OFF: 1
  #   observability.NewTracer            inlining ON: 1 symbol    OFF: 1
  #
  # InstallPropagation is genuinely called -- from NewTracer, which is called
  # at cmd/<SERVICE>/main.go:110 -- and is small enough that the compiler
  # inlines it away entirely. With inlining left on, this row would report a
  # WIRED mechanism as ELIMINATED-BY-LINKER, which is the false positive that
  # gets a row switched off within a week. NewTracer is too big to inline and
  # resolves either way, which is why one example is not enough to see this.
  if ! driven_build=$(go build -gcflags=all=-l -o "$driven_bin/" ./cmd/... 2>&1); then
    row "mechanisms-driven" FAIL "cannot build ./cmd/... so wiring is unprovable: $(grep -m1 -oE '[^ ]+\.go:[0-9]+:[0-9]+: .*' <<<"$driven_build" | cut -c1-100)"
  else
    # Every binary in the directory: a mechanism wired into ONE entrypoint is
    # wired, and reading only the first would call it dead.
    driven_syms=$(find "$driven_bin" -type f -perm -u+x 2>/dev/null \
                  | while IFS= read -r b; do go tool nm "$b" 2>/dev/null; done)
    d_total=0; d_ok=0; d_missing=""
    while IFS= read -r dk; do
      [[ -n "$dk" ]] || continue
      d_total=$((d_total+1))
      dsym="$(driven_symbol "$dk")"
      if [[ -z "$dsym" ]]; then
        d_missing="${d_missing} ${dk}:no-symbol-declared"
      # The symbol must END the nm line. A substring match is not enough, and
      # the failure it admits is the worst kind: swapping a real constructor
      # for a no-op one leaves the ORIGINAL name matching as a PREFIX of the
      # replacement, so the row passes a service whose mechanism was just
      # disabled.
      #
      # Caught by mutation, on a template that then had `observability.New`
      # and `observability.NewNoop` -- neither symbol exists there any more,
      # so this is recorded as the HISTORY it is rather than as a measurement
      # someone could re-run. The shape is what generalises: any Foo / FooNoop,
      # Open / OpenInMemory, Real / RealDisabled pair reproduces it, and
      # anchoring to end-of-line makes them the distinct symbols they are.
      elif grep -qE "[ /.]$(printf '%s' "$dsym" | sed 's/[][\.*^$(){}?+|/]/\\&/g')\$" <<<"$driven_syms"; then
        d_ok=$((d_ok+1))
        # Method form -- `pkg.(*Type).Method` or `pkg.Type.Method`. Collected
        # so the PASS text can say its evidence is weaker for these. See the
        # asymmetry note above: the linker keeps a type's whole method set
        # once that type reaches an interface, so presence stops proving a
        # caller. This is how a template with NO reconcile loop scored green.
        # A `case` rather than a regex, deliberately: the ERE form of this
        # (`\.\(\*?…\)\.`) fails to compile in bash's engine with
        # "repetition-operator operand invalid", and a pattern that silently
        # never matches would make this whole caveat decorative -- which is
        # the defect the caveat is about.
        case "$dsym" in
          *"("*")."*)  d_methods="${d_methods:-} ${dk}(${dsym})" ;;  # pkg.(*T).M
          *.*.*)       d_methods="${d_methods:-} ${dk}(${dsym})" ;;  # pkg.T.M
        esac
      else
        d_missing="${d_missing} ${dk}(${dsym}):ELIMINATED-BY-LINKER"
      fi
    done < <(driven_keys)
    rm -rf "$driven_bin"
    if (( d_total == 0 )); then
      row "mechanisms-driven" FAIL "driven: block parsed to zero entries -- a check of nothing must never read as clean"
    elif [[ -n "$d_missing" ]]; then
      row "mechanisms-driven" FAIL "$((d_total-d_ok))/$d_total declared mechanism(s) are NOT reachable from main:${d_missing}"
    else
      # A declared symbol in METHOD form (`pkg.(*Type).Method` or
      # `pkg.Type.Method`) is weak evidence: if Type reaches any interface,
      # the linker retains its whole method set and presence proves nothing
      # about callers. Name the caller instead. Reported, not failed -- the
      # declaration may still be correct, and a row that FAILED here would
      # punish repos whose mechanism genuinely has no wrapper.
      if [[ -n "${d_methods:-}" ]]; then
        row "mechanisms-driven" PASS "$d_ok/$d_total declared mechanism(s) survive linking from ./cmd/... -- WEAK for:${d_methods}. Those are methods; if the receiver type reaches an interface the linker keeps the whole method set, so presence does not prove a caller. Declare the function that DRIVES the mechanism instead"
      else
        row "mechanisms-driven" PASS "$d_ok/$d_total declared mechanism(s) survive linking from ./cmd/... -- production reaches each"
      fi
    fi
  fi
fi

# --- 14. security: RUN the scanners ---------------------------------------
if [[ -x "$(gobin)/govulncheck" ]] || have govulncheck; then
  vout=$(PATH="$(gobin):$PATH" govulncheck ./... 2>&1)
  # govulncheck has TWO clean phrasings and the difference is not cosmetic: a
  # module with non-stdlib dependencies gets "Your code is affected by 0
  # vulnerabilities", while one with none at all gets "No vulnerabilities
  # found." A match on only the first turns every zero-dependency module — the
  # exact shape of a freshly scaffolded service — into a FAIL whose evidence
  # string is EMPTY, because the count grep finds nothing either. An
  # evidence-free FAIL is the worst output this probe can produce: it names no
  # defect, so the only available "fix" is to soften the probe.
  #
  # Verified empirically against govulncheck v1.7.0 on 2026-08-17: a module with
  # a vulnerable-but-uncalled indirect dependency printed the "affected by 0"
  # form, and a module with no non-stdlib dependencies at all printed "No
  # vulnerabilities found." Both are clean verdicts; only the phrasing differs.
  if grep -qE "affected by 0 vulnerabilities|No vulnerabilities found" <<<"$vout"; then
    row "vuln-scan" PASS "govulncheck: 0 called vulnerabilities"
  elif found=$(grep -m1 -E 'affected by [0-9]+ vulnerabilit' <<<"$vout"); then
    row "vuln-scan" FAIL "$found"
  else
    # Neither a clean verdict nor a count: the scanner did not complete (module
    # resolution, network, toolchain). That is an unproven gate, not a clean one.
    row "vuln-scan" FAIL "govulncheck produced no verdict — gate unproven: $(head -1 <<<"$vout")"
  fi
else row "vuln-scan" FAIL "govulncheck not installed — gate unproven"; fi

wf=".github/workflows"
if [[ -d $wf ]]; then
  # --- the CI definitions themselves must be VALID -------------------------
  # This probe exists because of a real outage, and it is the one check that
  # provably cannot live inside CI. A job missing `steps:` makes the whole
  # workflow file invalid, and GitHub's response is not a red job: it creates a
  # zero-second failed run with NO jobs and NO check runs, so the PR reports
  # "no checks reported", every required context stays unfulfilled forever, and
  # nothing turns red to explain why. Every other gate in this file was green
  # while the repo had no presubmit at all. An unrunnable gate is indis-
  # tinguishable from a passing one unless something OUTSIDE it looks.
  if have actionlint || [[ -x "$(gobin)/actionlint" ]]; then
    # Self-hosted runner labels are unknown to actionlint. Ignore ONLY that
    # rule: on the real defect its 8 label warnings buried the one line that
    # mattered, which is how the syntax error shipped in the first place.
    if alout=$(PATH="$(gobin):$PATH" actionlint -ignore 'label ".+" is unknown' "$wf"/*.y*ml 2>&1); then
      row "workflow-definitions-valid" PASS "actionlint clean on $(ls "$wf"/*.y*ml 2>/dev/null | wc -l | tr -d ' ') workflow file(s)"
    else
      row "workflow-definitions-valid" FAIL "$(grep -m1 -E '\.ya?ml:[0-9]+:[0-9]+:' <<<"$alout")"
    fi
  else row "workflow-definitions-valid" FAIL "actionlint not installed — CI definitions unvalidated, and an invalid one yields NO checks at all"; fi

  sc=$(grep -rl "secret-scan" $wf 2>/dev/null | wc -l | tr -d ' ')
  (( sc >= 2 )) && row "secret-scan-all-triggers" PASS "in $sc workflows" || row "secret-scan-all-triggers" FAIL "only $sc workflow(s) — PR-only is the known gap"
  # PARSED BY yq, NOT BY A REGEX, and not by PyYAML either. Measured on
  # clc-ci-medium (binance-marketdata#26, job 97552813207): the runner has no
  # PyYAML, so the first version of this row reported
  # `FAIL  PyYAML unavailable ... went UNCHECKED` -- correct behaviour, and
  # useless as a gate. `yq` is a Go binary pinned and installed by the same
  # `go install ...@version` step that already brings actionlint and
  # govulncheck into this job, so it costs no new kind of dependency. The
  # LOGIC then runs on python3 + the `json` stdlib, which is always present.
  #
  # Fails CLOSED on a missing parser. An "I could not check" that renders as
  # PASS is the failure mode this whole file exists to prevent.
  # THE PROGRAM LIVES IN A MARKED HEREDOC so the selftest can lift it out and
  # run it over scratch fixtures instead of restating its logic -- the same
  # shape `non-vacuity-selftest.sh` already uses for the PYNV block, and for the
  # same reason: a selftest that reimplements the parser tests the copy, not the
  # thing that runs. It is assigned to a variable rather than piped directly so
  # stdin stays free for the yq output the program actually reads.
  _sbom_py="$(cat <<'PYSBOM'

import sys, json

# Which reusable workflow touches WHICH artifact. Read from the sources at
# clcsolutions/ci@main, not inferred from job names -- an earlier version of
# this check listed sbom-scan.yaml as an image consumer and reported a defect
# that does not exist:
#
#   sbom.yaml:52        downloads ${artifact-name}-image, uploads -sbom
#   sbom-scan.yaml:80   downloads ${artifact-name}-sbom   <-- NOT the image
#   image-push.yaml:55  downloads ${artifact-name}-image
#   image-push.yaml:144 DELETES   ${artifact-name}-image
#
# So the ordering invariant binds `sbom` and `push`, and says nothing about
# `sbom-scan`, which reads a different artifact entirely. Whether the deploy
# should ALSO wait on the vulnerability scan is a policy question, not a race.
#
# LIMIT, stated rather than implied: this map is a SNAPSHOT. Swept
# clcsolutions/ci@main 2026-08-24 -- image-push.yaml is the only reusable
# workflow there that deletes an artifact (grepped all of image-push,
# image-promote, release, go-docker-build, sbom, sbom-scan). A NEW deleting
# workflow added later would be invisible to this row. The row is scoped per
# workflow FILE, which is correct because artifacts are per-run: a job in
# pr.yaml cannot consume an artifact a job in ci.yaml deleted.
CONSUMES = {"sbom.yaml": "image", "image-push.yaml": "image", "sbom-scan.yaml": "sbom"}
DELETES  = {"image-push.yaml": "image"}

any_consumer = False
any_deleter  = False
problems, proven = [], []

for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw or "\t" not in raw:
        continue
    fname, payload = raw.split("\t", 1)
    if payload.strip() == "PARSE_ERROR" or not payload.strip():
        problems.append("%s is unparseable" % fname)
        continue
    try:
        jobs = {j["job"]: j for j in json.loads(payload)}
    except Exception:
        problems.append("%s is unparseable" % fname)
        continue

    def wf_of(name):
        u = jobs[name].get("uses") or ""
        for w in CONSUMES:
            if w in u:
                return w
        return None

    def needs(name):
        n = jobs[name].get("needs") or []
        return [n] if isinstance(n, str) else list(n)

    def kind(name):
        w = wf_of(name)
        return None if w is None else (CONSUMES[w], jobs[name].get("art") or "")

    any_consumer |= any((wf_of(n) or "") == "sbom.yaml" for n in jobs)

    for d in jobs:
        w = wf_of(d)
        if w not in DELETES:
            continue
        any_deleter = True
        gone = (DELETES[w], jobs[d].get("art") or "")
        seen, stack = set(), list(needs(d))
        while stack:                                   # transitive: an edge via
            x = stack.pop()                            # another job counts too
            if x in seen or x not in jobs:
                continue
            seen.add(x)
            stack.extend(needs(x))
        # THE SET BEFORE ITS MEMBERS. Checking "every consumer is ordered before
        # the deleter" says nothing when there are NO consumers: an empty set
        # satisfies the claim, so this row reached its PASS branch with an empty
        # `proven` and printed `PASS  SBOM ordered before the artifact deleter ()`
        # -- certifying ordering on a lane with no sbom job at all, while push
        # still deleted the image and shipped it to DOCR. Reported by agatticelli
        # and escalated by fd1az on binance-marketdata#26, and it is the same
        # shape as the textual row this check replaced: green over a measurement
        # it never made.
        same = [c for c in jobs if c != d and kind(c) == gone]
        if not same:
            problems.append(
                "%s: %r deletes the %s artifact and ships it, but NO job in this workflow reads it -- nothing inventories what is deployed"
                % (fname, d, gone[0]))
            continue
        for c in same:
            if c in seen:
                proven.append("%s before %s" % (c, d))
            else:
                problems.append(
                    "%s: %r downloads the %s artifact that %r DELETES, and is not in its needs"
                    % (fname, c, gone[0], d))

if not any_consumer:
    print("FAIL|no job uses sbom.yaml -- the word may be in comments, the job is not there")
elif problems:
    print("FAIL|" + "; ".join(problems[:2]))
elif not any_deleter:
    print("PASS|SBOM job present; no artifact-deleting job in the graph to order against")
elif not proven:
    print("FAIL|an artifact-deleting job exists but nothing was proven ordered before it -- no evidence to report")
else:
    print("PASS|SBOM ordered before the artifact deleter (%s)" % ", ".join(sorted(set(proven))[:3]))
PYSBOM
)"
  if command -v yq >/dev/null 2>&1; then
    sbom_v="$(
      for _f in "$wf"/*.yml "$wf"/*.yaml; do
        [ -e "$_f" ] || continue
        printf '%s\t' "$(basename "$_f")"
        yq -o=json -I=0 '[.jobs // {} | to_entries[] | {"job": .key, "uses": (.value.uses // ""), "needs": (.value.needs // []), "art": (.value.with."artifact-name" // "")}]' "$_f" 2>/dev/null || printf 'PARSE_ERROR'
        printf '\n'
      done | python3 -c "$_sbom_py"
    )"
  else
    sbom_v="FAIL|yq not installed -- the SBOM ordering invariant went UNCHECKED (pin it with go install github.com/mikefarah/yq/v4, as this job already does for actionlint)"
  fi
  # An empty verdict means the pipeline itself failed to run. Treat that as a
  # FAIL for the same reason: unchecked is not passed.
  [ -n "$sbom_v" ] || sbom_v="FAIL|the sbom probe produced no verdict -- the ordering invariant went UNCHECKED"
  row "sbom" "${sbom_v%%|*}" "${sbom_v#*|}"
  # Match only real attestation mechanisms, never the English word "provenance"
  # (it appears in benchmark baseline headers — that was a false PASS before).
  # Strip comments before matching: an earlier version PASSed on a comment
  # that explained why provenance is impossible. Only executable lines count.
  # Read once into a variable instead of piping into `grep -q`.
  #
  # `producer | grep -q PATTERN` under `set -o pipefail` is a latent race: -q
  # exits at the first match and closes the pipe, and if the producer is still
  # writing it takes SIGPIPE (141), which pipefail then reports as the
  # pipeline's status -- turning a match into a FAIL, nondeterministically. It
  # does not bite while the input fits the 64KB pipe buffer (this repo's four
  # workflows are ~683 lines, so the producer always finishes first), which is
  # exactly what makes it the kind of bug that appears years later on a bigger
  # repo and looks like anything but a probe defect. A subagent reported seeing
  # this row alternate; I could not reproduce it in 40 runs across two trees,
  # so the flake itself stays UNCONFIRMED -- but the hazard is real, removing it
  # costs nothing, and a gate that might be nondeterministic is not a gate.
  wf_exec="$(grep -rhE "^[^#]*" $wf/*.yaml 2>/dev/null | sed 's/#.*//' || true)"
  if grep -qE "cosign|--provenance=|actions/attest|attestations:" <<<"$wf_exec"; then
    row "artifact-provenance" PASS "signing/attestation step present"
  elif waived artifact-provenance-signing; then
    row "artifact-provenance" NA "live waiver with owner+expiry in registries/waivers.yaml"
  else row "artifact-provenance" FAIL "no provenance and no live waiver (an expired or missing waiver is not an exemption)"; fi
fi

# --- 15. CI lanes ---------------------------------------------------------
grep -q "^check-fast:" Makefile 2>/dev/null && row "cheap-gate" PASS "make check-fast exists" || row "cheap-gate" FAIL "no cheap gate"
grep -q "^test-advisory:" Makefile 2>/dev/null && row "advisory-lane" PASS "make test-advisory exists" || row "advisory-lane" FAIL "no advisory lane"
ls $wf/nightly* >/dev/null 2>&1 && row "nightly-trends" PASS "nightly workflow present" || row "nightly-trends" FAIL "no scheduled trend lane"

# --- 16. ops artifacts (present AND their citations resolve) --------------
for f in docs/RUNBOOK.md docs/SLO.md observability/alerts.md CODEOWNERS; do
  [[ -f $f ]] && row "ops:$(basename "$f")" PASS "present" || row "ops:$(basename "$f")" FAIL "missing"
done
if [[ -f docs/RUNBOOK.md && -f observability/emitted-metrics.yaml ]]; then
  # Derive the series-name pattern from the MANIFEST, never from one org's
  # hardcoded prefix.
  #
  # This row used to grep for `clc[a-z]*_[a-z0-9_]+`. For any repo whose
  # series are not clc-prefixed that matched nothing, counted zero failures,
  # and reported "every cited series exists" having checked NOTHING -- a
  # green row that had verified precisely zero citations. The template's own
  # metrics are svc_*, so the standard shipped this row passing vacuously
  # against ITSELF, which is the exact defect class the whole framework
  # exists to catch.
  #
  # Second defect in the same two lines: the membership test was
  # `grep -q "$m" <manifest>`, a SUBSTRING search. A truncated or misspelled
  # citation like `svc_units_conserved` matched the manifest line for
  # `svc_units_conserved_violations_total` and resolved happily. The test is
  # now an exact match against the declared names.
  mapfile -t declared_series < <(grep -oE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*' observability/emitted-metrics.yaml | awk '{print $NF}' | sort -u)
  # The prefixes actually in use (token up to and including the first "_").
  mapfile -t series_prefixes < <(printf '%s\n' "${declared_series[@]}" | sed -E 's/^([a-zA-Z]+_).*/\1/' | sort -u)
  cited=0; bad=0; missing=""
  if ((${#series_prefixes[@]})); then
    _pat="$(printf '%s|' "${series_prefixes[@]}")"; _pat="(${_pat%|})"
    while read -r m; do
      [[ -n "$m" ]] || continue
      # A Prometheus series name never ENDS in an underscore. A token that does
      # is the prefix half of an alternation the runbook wrote for a human --
      # `grep -E 'clcbinance_ws_(connects_total|reconnects_total)'` -- and the
      # extractor stops at the `(`, inventing a series that was never cited.
      # Measured in clcsolutions/binance-marketdata: two such "missing" series,
      # `clcbinance_ws_` and `clcmd_venue_`, both from legitimate runbook
      # commands. A gate that invents a citation and then reports it unresolved
      # sends someone to fix a document that was correct.
      [[ "$m" == *_ ]] && continue
      cited=$((cited+1))
      printf '%s\n' "${declared_series[@]}" | grep -qx "$m" || { bad=$((bad+1)); missing="${missing} $m"; }
    done < <(grep -ohE "\\b${_pat}[a-z0-9_]+\\b" docs/RUNBOOK.md | sort -u)
  fi
  if (( bad > 0 )); then
    row "runbook-citations-resolve" FAIL "$bad of $cited cited series do not exist:${missing}"
  elif (( cited == 0 )); then
    row "runbook-citations-resolve" FAIL "RUNBOOK cites ZERO of the ${#declared_series[@]} declared series -- nothing was checked, and nothing-checked is not everything-resolves"
  else
    row "runbook-citations-resolve" PASS "$cited/${#declared_series[@]} declared series cited, all resolve"
  fi
fi
for r in flags waivers quarantine contract-debt; do
  [[ -f registries/$r.yaml ]] || { row "registries" FAIL "registries/$r.yaml missing"; break; }
done
[[ -f registries/contract-debt.yaml ]] && row "registries" PASS "4 liability registries present"
if [[ -x scripts/check-registries.sh ]]; then
  if out=$(bash scripts/check-registries.sh 2>&1); then
    row "registries-expiry-gated" PASS "$(grep -oE '[0-9]+ entries checked[^,]*' <<<"$out" | head -1); expiry gates the build"
  else row "registries-expiry-gated" FAIL "$(grep -m1 EXPIRED <<<"$out")"; fi
else row "registries-expiry-gated" FAIL "registries are recorded but nothing enforces expiry — a stale waiver is a permanent silent exemption"; fi

# --- 17. contract artifacts exist for the work (audit finding: never written) --
ctxdir="${PROD_CONTEXT_DIR:-.prod/context}"
if ls "$ctxdir"/*resolved-context*.y*ml >/dev/null 2>&1 && ls "$ctxdir"/*change-plan*.y*ml >/dev/null 2>&1; then
  row "contract-artifacts" PASS "resolved-context + change-plan present in $ctxdir"
else row "contract-artifacts" FAIL "no resolved-context/change-plan in $ctxdir — nothing to audit the diff against"; fi

# --- 18. ratification packages back every ratified invariant -----------------
if ls verification/ratified/*_test.go >/dev/null 2>&1; then
  # Same class of bug as the fuzz counter above, and it survived that fix
  # because I repaired the instance that bit instead of sweeping the pattern:
  # `grep -c` prints "0" AND exits non-zero on zero matches, so `|| echo 0`
  # appends a SECOND line and every later (( )) throws. This one only fires when
  # the spec exists with an EMPTY invariants list -- a freshly bootstrapped repo,
  # precisely the state this probe is pointed at first.
  inv=$(grep -cE '^[[:space:]]*-[[:space:]]' <(sed -n '/^invariants:/,/^[a-z_]*:/p' "$SPEC" 2>/dev/null) 2>/dev/null | head -1)
  inv=${inv:-0}
  pkgs=$(ls "$RATIFY_QUEUE_DIR"/*.y*ml 2>/dev/null | wc -l | tr -d ' ')
  if (( pkgs > 0 && pkgs >= inv )); then row "ratification-packages" PASS "$pkgs packages for $inv ratified invariants"
  else row "ratification-packages" FAIL "$pkgs ratification packages for $inv ratified invariants — the queue is the evidence trail"; fi

  # Every package's `test.function` must name a test that EXISTS. The probe
  # executes `expect_red`, so a package can carry a `function:` naming a test
  # that was renamed or deleted and stay green forever -- the citation rots
  # into a tombstone and the package still reads as evidence. Found in
  # clcsolutions/marketdata: 004 cited TestFailedFetchNeverReplacesLiveCatalog
  # while the test is TestFailedFetchNeverDestroysLastKnownDrift, and nothing
  # in the gate could tell.
  rp_missing=""
  rp_drift=""
  rp_checked=0
  for rp in "$RATIFY_QUEUE_DIR"/*.y*ml; do
    [[ -f "$rp" ]] || continue
    # ONE parser, the same one the non-vacuity row uses to decide what to
    # execute. This used to be two independent awk expressions and they
    # disagreed in BOTH directions -- measured by a reviewer against the real
    # packages: `expect_red:Foo` (no space after the colon, which YAML allows
    # and the stdlib parser reads fine) made the awk return empty, so the drift
    # check SILENTLY SKIPPED while the row printed PASS claiming it had
    # compared them; and a legally single-quoted `expect_red: 'Foo'` produced a
    # false FAIL, because the awk does not strip quoting and the real parser
    # does. A row that asserts a comparison it did not perform is worse than no
    # row.
    rp_fn=$(cited_function "$rp")
    rp_red=$(executed_function "$rp")
    [[ -z "$rp_fn" ]] && continue
    rp_checked=$((rp_checked+1))
    grep -rqE "func[[:space:]]+${rp_fn}\(" --include='*_test.go' . 2>/dev/null \
      || rp_missing+="$(basename "$rp"):$rp_fn "
    # And it must be the SAME test the non_vacuity_check EXECUTES.
    #
    # Checking only that the cited function exists is weaker than what the
    # packages themselves promise: their comment says the declarative citation
    # is taken from expect_red "so the two cannot drift into naming different
    # tests". Existence alone permits exactly that drift -- cite test A, execute
    # test B, both real, gate green, and the package's evidence describes
    # something the probe never ran. A gate weaker than the comment it enforces
    # leaves the comment doing the work.
    # No `-n "$rp_red"` guard any more: an EMPTY expect_red used to make the
    # comparison skip silently, which is exactly the fail-open above. A package
    # that cites a function and executes nothing is drift too.
    drift=$(citation_drift "$rp")
    [[ -n "$drift" ]] && rp_drift+="$drift "
  done
  if (( rp_checked == 0 )); then
    row "ratification-citations" FAIL "no ratification package declares a test.function — the citation is what makes the package evidence"
  elif [[ -n "$rp_missing" ]]; then
    row "ratification-citations" FAIL "cited test(s) do not exist: $rp_missing"
  elif [[ -n "$rp_drift" ]]; then
    row "ratification-citations" FAIL "cited test != executed test: $rp_drift -- the package names one test as its evidence and the non-vacuity check runs another"
  else
    row "ratification-citations" PASS "$rp_checked cited test function(s) resolve AND match the test each non_vacuity_check executes"
  fi
fi

# --- 19. candidate tests are segregated OUT of the blocking lane -------------
# Matched as a PROVENANCE HEADER (`// provenance: candidate` at the start of a
# comment line), not as the bare string anywhere in the file. The loose form
# counted a file that merely MENTIONS the convention in prose -- it fired on a
# comment reading "only `provenance: candidate` files carry a ttl", declaring a
# blocking-lane file an untagged candidate. Same shape as a citation being
# indistinguishable from a tombstone: a checker that reads prose cannot tell a
# declaration from a discussion of one.
cand=$(grep -rlE '^[[:space:]]*//[[:space:]]*provenance:[[:space:]]*candidate[[:space:]]*$' --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
tagged=$(grep -rl "go:build candidate" --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
if (( cand == 0 )); then row "candidate-lane-segregated" NA "no candidate tests"
elif (( tagged >= cand )); then row "candidate-lane-segregated" PASS "$cand candidate files, all build-tagged"
else row "candidate-lane-segregated" FAIL "$((cand-tagged)) of $cand candidate files run in the BLOCKING lane"; fi

# --- 20. provenance headers on every ADDED test func ------------------------
# Only functions the diff ADDS are in scope: pre-existing tests in a touched
# file predate the convention and are not this change's debt.
# THE OUTER `if` HAD NO `else`, so a checkout where the base ref cannot be
# resolved emitted NO ROW AT ALL. The not-probed meta-guard then turned that
# into a counted FAIL whose message says the row "counts in neither PASS, FAIL
# nor NA" -- a dimension reported as unmeasurable by a guard, rather than by
# the dimension itself, which is the least actionable form the report can take.
# Reported by fd1az on okx-marketdata#8.
#
# Two halves. First, stop failing to resolve a base that usually exists: a CI
# checkout may have `main` without `origin/main`, or the default branch may not
# be called main at all, so try the remote HEAD the repo actually declares
# before giving up. Second, when none of them resolve, SAY SO in a row of this
# dimension's own -- and say it as FAIL, because "I could not measure whether
# added tests carry provenance headers" is not a ratified decline.
prov_base=""
for _ref in origin/main main "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; do
  [ -n "$_ref" ] || continue
  if prov_base=$(git merge-base HEAD "$_ref" 2>/dev/null) && [ -n "$prov_base" ]; then break; fi
  prov_base=""
done
if base="$prov_base"; [ -n "$base" ]; then
  # Benchmarks are excluded: they are neither blocking nor candidate — they
  # live in their own non-gating lane, so a provenance header would claim a
  # lane membership they do not have.
  added=$(git diff "$base"..HEAD -- '*_test.go' 2>/dev/null | grep -cE '^\+func (Test|Fuzz)' || true)
  # an added func is "headed" when a provenance line is added within the diff too
  heads=$(git diff "$base"..HEAD -- '*_test.go' 2>/dev/null | grep -cE '^\+.*provenance:' || true)
  if (( added == 0 )); then row "provenance-headers" NA "no test funcs added"
  elif (( heads >= added )); then row "provenance-headers" PASS "$added added test funcs, $heads provenance lines"
  else row "provenance-headers" FAIL "$added added test funcs but only $heads provenance headers ($((added-heads)) unheaded)"; fi
else
  row "provenance-headers" FAIL "no diff base resolves (tried origin/main, main, origin/HEAD) -- this dimension went UNMEASURED, which is not the same as met"
fi

# --- 21. CI actually runs what the standard requires ------------------------
nfuzz=${#fuzzes[@]}
# NOT `grep -c ... || echo 0`. grep -c on a file that EXISTS with zero matches
# prints "0" AND exits non-zero, so the fallback fires too and the variable
# becomes "0\n0" -- which makes (( )) throw an arithmetic syntax error and
# leaves the row's evidence as a bare "0". Found the first time this probe ran
# against a repo that had a Makefile with no fuzz targets, which is the ordinary
# case for any repo not yet on the standard.
inmake=$(grep -c 'Fuzz[A-Za-z0-9_]*' Makefile 2>/dev/null | head -1)
inmake=${inmake:-0}
# Counting fuzz NAMES in the Makefile certifies nothing about CI: a variable
# listing every target satisfies it while no job on earth invokes them. The row
# is called ci-runs-fuzz, so it has to find the INVOCATION -- either a workflow
# step that fuzzes directly (`-fuzz=`), or one that calls a make target whose
# own recipe does. The make targets are resolved from the Makefile rather than
# guessed by name, because `fuzz`, `fuzz-guard` and `check-fast` are this
# repo's names, not the standard's.
fuzz_make_targets=$(awk '
  /^[a-zA-Z0-9_.\-]+:/ { split($0, a, ":"); cur = a[1]; next }
  /^\t/ && (/-fuzz[= ]/ || /Fuzz[A-Za-z0-9_]*/) { if (cur != "") print cur }
' Makefile 2>/dev/null | sort -u)
fuzz_ci_evidence=""
if grep -rqE -- '-fuzz=' $wf 2>/dev/null; then
  fuzz_ci_evidence="a workflow step fuzzes directly"
else
  while IFS= read -r mt; do
    [[ -z "$mt" ]] && continue
    if grep -rqE "make (--[a-z-]+ )*$mt( |\$|\")" $wf 2>/dev/null; then
      fuzz_ci_evidence="a workflow runs 'make $mt'"; break
    fi
  done <<<"$fuzz_make_targets"
fi
if (( nfuzz == 0 )); then
  row "ci-runs-fuzz" FAIL "no fuzz targets exist, so nothing is wired: $inmake fuzz name(s) in Makefile"
elif [[ -z "$fuzz_ci_evidence" ]]; then
  row "ci-runs-fuzz" FAIL "$nfuzz fuzz target(s) and $inmake name(s) in the Makefile, but NO workflow invokes any of them — a name in a Makefile is not a lane"
elif (( inmake >= nfuzz )); then
  row "ci-runs-fuzz" PASS "$nfuzz target(s), all named in the Makefile, and $fuzz_ci_evidence"
else
  row "ci-runs-fuzz" FAIL "$inmake of $nfuzz fuzz targets named in the Makefile — the rest run nowhere ($fuzz_ci_evidence)"
fi
if [[ -n "${real_tag:-}" ]]; then
  grep -rq -- "-tags=$real_tag\|tags: *$real_tag" Makefile $wf 2>/dev/null     && row "ci-runs-integration-lane" PASS "'$real_tag' lane wired into make/CI"     || row "ci-runs-integration-lane" FAIL "'$real_tag' lane exists but no make target or CI job runs it"
fi
grep -rq "diff-cover\|patch coverage\|changed-line" Makefile $wf scripts 2>/dev/null   && row "changed-line-coverage" PASS "changed-line signal wired"   || row "changed-line-coverage" FAIL "changed-line coverage (every tier's SIGNAL) is measured nowhere"

# --- 22. reproducibility / operational determinism (restored dimension) -----
# Probe the EFFECT: a revision that CAN be non-empty in the shipped artifact.
# An earlier version passed on the mere presence of the wiring while every image
# CI built shipped revision="" — .dockerignore excluded .git, so -buildvcs had
# nothing to stamp and no --build-arg path existed. That false green is exactly
# what this dimension is now checked against.
if grep -rqE "commit|git_sha|config_version|schema_version|build_info" observability/*.yaml observability/*.md 2>/dev/null; then
  stampable="unknown"
  if [[ -f .dockerignore ]] && grep -qxE '\.git/?' .dockerignore; then
    grep -rq "GIT_SHA\|ldflags" docker/ 2>/dev/null && stampable="ldflags" || stampable="no"
  else stampable="buildvcs"; fi
  case "$stampable" in
    no) row "operational-determinism" FAIL "signals declare a revision but .dockerignore excludes .git and no ldflags path exists — every image ships revision=\"\"" ;;
    *)  row "operational-determinism" PASS "versions surfaced; revision stampable via $stampable" ;;
  esac
else row "operational-determinism" FAIL "Output=F(code,config,state,inputs): the four versions are not surfaced — replay cannot reproduce prod"; fi

# --- report --------------------------------------------------------------
# --- SILENCE IS NOT A VERDICT -----------------------------------------------
#
# A row that is never emitted counts in neither PASS, FAIL nor NA: it evaporates
# from the report AND from the tally, and the run still ends COMPLETE. That is
# the quietest failure this file can have -- worse than a red row, because
# nothing draws the eye to it.
#
# It is reachable through ordinary conditionals. Measured on a repo without a
# docs/RUNBOOK.md, `runbook-citations-resolve` simply does not appear; on a repo
# whose tests carry no `//go:build` integration tag, `ci-runs-integration-lane`
# does not appear even when the lane exists; and every §14/§15 security row sits
# inside `if [[ -d $wf ]]`, so a repo with no .github/workflows loses four rows
# without a single FAIL.
#
# So: the dimension names this script CAN emit are derived from its own source,
# and any one that produced no row becomes FAIL "not probed". Derived rather
# than hand-listed so it cannot drift out of date -- a hand-maintained list is
# one more thing that silently stops matching.
#
# Rows whose name is built from a variable are invisible to this derivation and
# are simply extra; the guard is one-directional on purpose.
declared_rows=$(grep -oE '^[[:space:]]*(el)?(se)?[[:space:]]*row "[a-zA-Z][^"$]*"' "$0" \
  | sed -E 's/.*row "([^"]*)".*/\1/' | sort -u)
if (( $(grep -c . <<<"$declared_rows") < 20 )); then
  # The derivation itself must not fail open. If it stops matching, this guard
  # would silently protect nothing -- exactly the shape it exists to catch.
  ROWS+=("row-derivation|FAIL|could not derive the declared dimension list from this script -- the not-probed guard is inert")
  fails=$((fails+1))
else
  emitted_rows=$(printf '%s\n' "${ROWS[@]}" | cut -d'|' -f1 | sort -u)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    grep -qxF "$d" <<<"$emitted_rows" && continue
    ROWS+=("$d|FAIL|not probed: no branch emitted this dimension, and an unemitted row counts in neither PASS, FAIL nor NA")
    fails=$((fails+1))
  done <<<"$declared_rows"
fi

printf '\n%-34s %-5s %s\n' "DIMENSION" "VERDICT" "EVIDENCE"
printf '%s\n' "$(printf '%0.s-' {1..96})"
for r in "${ROWS[@]}"; do IFS='|' read -r d v e <<<"$r"; printf '%-34s %-5s %s\n' "$d" "$v" "$e"; done
printf '%s\n' "$(printf '%0.s-' {1..96})"
printf 'PASS %d   FAIL %d   NA %d\n' "$passes" "$fails" "$nas"

# Evidence record (dimension 11, reproducibility): one file per commit so the
# question "under what standard was this commit held?" is answerable later
# without archaeology. Ephemeral stdout is not a record.
#
# The filename is an ATTESTATION, so it must not be able to lie. Stamping
# `git rev-parse HEAD` onto a run measured on a DIRTY tree produces a record
# named after a commit it was never measured on — and that is not theoretical:
# a committed record named <sha>.json once claimed a PASS for a probe row that
# did not exist in that commit's tree, on a commit whose workflow file was
# invalid and would have FAILED it. A plausible-looking green attestation for a
# state that never passed is worse than no record at all.
#
# So: a record named <sha>.json means "measured on exactly that commit". A dirty
# tree gets a name that cannot be mistaken for one, and carries tree_clean:false.
sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  tree_clean=false
  record=".prod/evidence/dirty-${sha}-$(date -u +%Y%m%dT%H%M%SZ).json"
else
  tree_clean=true
  record=".prod/evidence/$sha.json"
fi
mkdir -p .prod/evidence
{
  printf '{\n  "commit": "%s",\n' "$sha"
  printf '  "tree_clean": %s,\n' "$tree_clean"
  printf '  "generated_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "spec": "%s",\n' "$SPEC"
  printf '  "tier": "%s",\n' "$(grep -m1 -E '^[[:space:]]*tier:' "$SPEC" 2>/dev/null | tr -d ' ' | cut -d: -f2)"
  printf '  "totals": { "pass": %d, "fail": %d, "na": %d },\n' "$passes" "$fails" "$nas"
  printf '  "probes": [\n'
  first=1
  for r in "${ROWS[@]}"; do IFS='|' read -r d v e <<<"$r"
    [[ $first -eq 1 ]] || printf ',\n'; first=0
    printf '    { "dimension": %s, "verdict": "%s", "evidence": %s }' \
      "$(printf '%s' "$d" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "$v" \
      "$(printf '%s' "$e" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  done
  printf '\n  ]\n}\n'
} > "$record"
echo "evidence record: $record${tree_clean:+}"
[[ "$tree_clean" == true ]] || echo "  (working tree DIRTY: this record is NOT an attestation for commit $sha)"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE — $fails probe(s) failed; each is a finding, not a reason to soften the probe."; exit 1; }
echo "VERDICT: COMPLETE — every dimension probed; N/A entries are ratified declines."
