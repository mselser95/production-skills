#!/usr/bin/env bash
# verify-standard.sh — probe every standard dimension and print PASS/FAIL/NA.
#
# This script's OUTPUT IS THE COMPLETION REPORT. It probes EFFECTS, not
# artifacts: it runs the tools, greps the entrypoints for wiring, and reads the
# spec's ratified declines.
#
# The rationale lives in the production-skills repo at
# _shared/verification-probes.md. It is deliberately NOT cited as a relative
# path: this file is VENDORED into each repo as scripts/verify-standard.sh, and
# `../verification-probes.md` resolves to nothing there -- a dangling citation
# in every repo that adopts the standard, which is the citation-vs-tombstone
# defect this file exists to refuse, appearing in its own header.
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
# Resolved BEFORE the cd below, and that ordering is the whole point.
#
# The not-probed guard derives the declared dimension list by grepping this
# script. It read "$0", which for the documented invocation
# `bash scripts/verify-standard.sh /path/to/other/repo` is a RELATIVE path --
# and by the time it is read, the cd has already moved out from under it. The
# derivation came back empty and the meta-guard fired with
# `row-derivation FAIL ... the not-probed guard is inert`: a red row on correct
# usage, on exactly the invocation that produced the two best findings of this
# change set (pointing the probe at a C++ repo).
#
# BASH_SOURCE[0] rather than $0 so it is right when sourced as well as executed.
PROBE_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
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
code_lines_only() { # filter `grep -rn` output down to lines that are CODE
  # `grep -rn` prints path:lineno:content. A content that starts with `//` is
  # PROSE, and every row in this file that greps for a call site is one doc
  # comment away from certifying it. Not hypothetical: clc-bitgo-marketdata's
  # internal/platform/obs/tracing.go documents the function by naming
  # `otel.SetTracerProvider` in its doc comment, ten lines above the call --
  # delete the call, keep the sentence, and an unfiltered count still reports a
  # wired provider.
  grep -vE '^[^:]*:[0-9]+:[[:space:]]*//'
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
classify_mutation_result() {   # <go-test-output> [test-name]
  local out="$1" tname="${2:-}"
  # A test that did not RUN is not a verdict, in either direction. Two live
  # traps, both observed: an integration-tagged invariant test without the tag
  # yields "[no test files]" (neither ok nor FAIL -> NO-VERDICT), and WITH the
  # tag but without a database it self-skips and the package prints a bare
  # "ok" -- which would classify the mutation STAYED-GREEN and accuse a
  # perfectly good invariant of being vacuous. Checking for the skip first is
  # what keeps "not run" from masquerading as either answer.
  # A REAL FAIL OUTRANKS A SIBLING'S "[no test files]".
  #
  # The skip test used to run FIRST, and `go test ./...` prints one line per
  # package: a sibling with no test files puts "[no test files]" in the same
  # output as the `--- FAIL` that proves the mutation was caught. Skip-first
  # then reported NOT-RE-VERIFIED over a genuine detection. It fails CLOSED --
  # the row lands in nv_broken -- so nothing was ever let through, but a
  # correct red reported under the wrong reason is how a correct red gets
  # argued away. Reported by agatticelli.
  #
  # A `--- FAIL` is a DEFINITE verdict about the mutated package; "[no test
  # files]" is the ABSENCE of one about another package. The definite answer
  # wins. The skip test keeps its place above the bare `^ok` branch, which is
  # the case its own comment was written for: a self-skip prints "ok" and
  # would otherwise read as STAYED-GREEN.
  # THE SECOND ARGUMENT, ADDED AT THE RECONCILIATION MERGE (2026-08-26), and
  # the reason it is not just a reordering.
  #
  # Two branches changed this function in OPPOSITE directions, each fixing a
  # real defect the other reintroduces:
  #
  #   fix/probe-block-scalars-and-comment-stripping moved FAIL ABOVE skip,
  #   because a sibling package's "[no test files]" was masking a genuine
  #   `--- FAIL` and reporting a real detection as NOT-RE-VERIFIED.
  #
  #   fix/registry-gate-block-scalars-and-template-rot shipped a selftest case
  #   requiring the OPPOSITE, because with FAIL above skip a run where OUR test
  #   SKIPPED and a SIBLING's test FAILED classifies as DETECTED -- certifying
  #   an invariant that was never measured. That is the fail-OPEN direction and
  #   the more dangerous of the two. Reported by fd1az on binance-marketdata#24.
  #
  # Ordering alone cannot satisfy both, because the question was never which
  # line comes first: it is WHOSE FAIL it is. So the caller passes the test it
  # mutated and the FAIL has to NAME it. With a name, both cases fall out:
  # a sibling's FAIL no longer matches, so the skip branch is reached and the
  # answer is NOT-RE-VERIFIED; our own FAIL matches and is DETECTED even when a
  # sibling printed "[no test files]".
  #
  # The name is OPTIONAL and the unscoped form keeps FAIL above skip, which is
  # the block-scalars ordering. That is deliberate: an unnamed call cannot tell
  # whose FAIL it is, and for that call the masking defect is the live one.
  #
  # WIRED, not merely offered. Branch B shipped the selftest case for this and
  # left both call sites passing one argument, so the scoping would have been
  # inert in production -- a guard that exists only in its own test. The call
  # sites below now pass "$nv_test".
  local _fail_re
  if [[ -n "$tname" ]]; then
    # Anchored to `--- FAIL: <name>` and bounded on the right so a mutation of
    # TestFoo is not certified by a failure of TestFooBar. `/` is allowed for
    # subtests (`--- FAIL: TestFoo/case_1`), which ARE our test failing.
    _fail_re="^[[:space:]]*--- FAIL: ${tname}([[:space:]]|/|\$)"
  else
    _fail_re="^(--- )?FAIL"
  fi
  if grep -qE "build failed|cannot use|undefined:|declared and not used|syntax error" <<<"$out"; then
    echo "MUTATION-BREAKS-BUILD"
  elif grep -qE "$_fail_re" <<<"$out"; then
    echo "DETECTED"
  elif grep -qE "^--- SKIP|no tests to run|\[no test files\]" <<<"$out"; then
    echo "NOT-RE-VERIFIED"
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

# The suite's DIRECTORY was hardcoded to internal/architecture, which is
# binance-marketdata's name for it, not the standard's. bitgo-marketdata calls
# the same suite internal/arch: the `||` fallback found its tests, then
# `go test ./internal/architecture/...` failed on a path that does not exist,
# and the row reported "architecture test red" for a suite that is green. A
# probe that hardcodes one repo's layout reports the FLEET's other repos as
# broken -- and a red row nobody can reproduce locally is how a gate loses its
# audience. Locate the package that holds the fitness tests instead.
# Locate it by NAME first. A keyword sweep alone is far too loose: matching
# /forbidden|ImportsOnly/ across every _test.go picked
# internal/adapter/out/bitgooracle in bitgo-marketdata, because the word
# "forbidden" appears in an error-message assertion there -- so the row would
# have run the wrong package and called it the fitness suite. Measured before
# claiming the fix.
fitness_dir=""
for _cand in internal/architecture internal/arch internal/fitness architecture arch; do
  if ls "$_cand"/*_test.go >/dev/null 2>&1; then fitness_dir="./$_cand"; break; fi
done
# Fallback keyed on what a fitness test DOES -- walk the import graph -- rather
# than on words that appear in ordinary assertions.
if [[ -z "$fitness_dir" ]]; then
  fitness_dir=$(grep -rlE 'go/parser|go/ast|tools/go/packages' --include='*_test.go' . 2>/dev/null \
                | xargs -I{} dirname {} 2>/dev/null | sort -u | head -1)
fi
if [[ -n "$fitness_dir" ]]; then
  if go test "$fitness_dir/..." -count=1 >/dev/null 2>&1; then
    empty=$(grep -A3 'wallClockAllowlist = map\[string\]bool{' "$fitness_dir"/*_test.go 2>/dev/null | grep -c '"' || true)
    row "fitness-functions" PASS "fitness suite green in ${fitness_dir#./}; wall-clock allowlist entries: $empty"
  else row "fitness-functions" FAIL "fitness suite in ${fitness_dir#./} is RED"; fi
else
  # Deliberately NOT widened to accept a shell script. kraken-marketdata and
  # okx-marketdata both carry scripts/check-architecture.sh wired into their
  # cheap gate, and that IS a fitness function -- but "a file with that name
  # exists" is the citation-vs-tombstone trap this standard exists to refuse,
  # and this row's contract is a suite the probe can RUN and read a verdict
  # from. So it stays FAIL and says exactly what it looked for, rather than
  # turning green on a filename.
  _shell_fitness=$(ls scripts/check-architecture.sh scripts/check-arch.sh 2>/dev/null | head -1)
  if [[ -n "$_shell_fitness" ]]; then
    row "fitness-functions" FAIL "no Go fitness suite in internal/{architecture,arch,fitness}; $_shell_fitness exists but this row does not certify a script by its name"
  else
    row "fitness-functions" FAIL "no architecture/fitness test found anywhere in the tree"
  fi
fi

# THE PROBE'S OWN FITNESS FUNCTION. `producer | grep -q PATTERN` under this
# file's `set -o pipefail` is the SIGPIPE race documented on the
# artifact-provenance and runbook-citations rows: -q exits at the first match,
# the producer takes SIGPIPE, and pipefail turns a MATCH into a FAIL. It cost
# clcsolutions/binance-marketdata a row that named a different set of
# declared-but-"missing" series on ~71% of runs.
#
# The rule lived only in a comment saying "do not reintroduce the pipe", and a
# comment is the weakest possible gate for a rule in a file that is VENDORED
# into every repo and edited mostly by agents -- it is how this defect survived
# being described correctly at least three times in this very file.
#
# `$PROBE_SELF`, NEVER `${BASH_SOURCE[0]}`. BASH_SOURCE is the raw invocation
# path and this row runs hundreds of lines AFTER `cd "$root"`, so with the
# documented `verify-standard.sh [repo-root]` usage it resolves against the
# TARGET repo: a two-repo fixture showed the row reporting PASS while the
# RUNNING probe carried the defect -- constructive proof of vacuity, on the one
# invocation this file's own header recommends. PROBE_SELF is absolute and
# computed before the cd. No fallback: if it is unset the row FAILS, because a
# self-check that cannot locate itself is not a check.
#
# WHAT THIS CATCHES, measured against a 24-case corpus: the plain pipe, inside
# `$(...)`, inside a function body, egrep/fgrep/zgrep/rg/ag, `--quiet` and any
# short flag containing q in any order, absolute paths, `command grep`, env-
# prefixed `LC_ALL=C grep -q`, no-space `a|grep -q`, tabs, and BOTH
# continuation shapes (trailing `\` and trailing `|`) including a `|` in
# column 0 -- logical lines are rejoined before matching, because an anchor
# that fits only the shape you happened to write is this file's own lesson.
#
# WHAT IT DOES NOT CATCH, stated so nobody reads more into a PASS than is
# there: indirection through a variable or alias (`G="grep -q"; ... | $G x`) is
# out of reach of static text matching; `grep PATTERN -q` with the flag after
# the pattern is not matched, because a pattern-position match would make this
# row fire on its own regex text; and other early-exit readers (`| head`,
# `| grep -m1`) are the same hazard class but are NOT covered here -- in this
# file they sit in `$(...)` value captures whose exit status is discarded.
#
# Second condition, same row: a GLOBAL `IFS=` assignment. The runbook-citations
# membership test joins with `"${declared_series[*]}"`, which uses the FIRST
# CHARACTER OF IFS, so a global IFS would make that row report declared series
# as missing again. Only standalone/exported assignments count: `local IFS=,`
# is the canonical safe array-join idiom and `IFS=$'\n' cmd` is scoped to its
# command -- forbidding those would be forbidding the correct fix.
#
# Line numbers are taken BEFORE comments are stripped. Numbering the stripped
# stream cited a line that does not exist (measured: real 2084 reported as 927)
# in a file whose header calls the dangling citation the defect it exists to
# refuse.
if [[ -n "${PROBE_SELF:-}" && -r "${PROBE_SELF:-}" ]]; then
  _nl=$'\001'
  _logical=$(grep -vE '^[[:space:]]*#' "$PROBE_SELF" | tr '\n' "$_nl" \
    | sed -e "s/\\\\${_nl}[[:space:]]*/ /g" -e "s/|${_nl}[[:space:]]*/| /g" | tr "$_nl" '\n')
  _greplike='(([A-Za-z_]+=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?([^[:space:]|]*/)?(grep|egrep|fgrep|zgrep|rg|ag))'
  _quietfl='([[:space:]]+-[A-Za-z]*)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet)([[:space:]]|$)'
  _pipegrep=$(printf '%s\n' "$_logical" | grep -E "(^|[^|])\|[[:space:]]*${_greplike}${_quietfl}" || true)
  _globalifs=$(grep -n '' "$PROBE_SELF" | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -E '^[0-9]+:[[:space:]]*(export[[:space:]]+)?IFS=[^[:space:];]*[[:space:]]*(;|$)' || true)
  if [[ -n "$_pipegrep" ]]; then
    row "probe-self:no-pipe-into-grep-q" FAIL "this probe pipes a producer into a quiet grep -- the SIGPIPE-under-pipefail race that reports a MATCH as a FAIL: ${_pipegrep//$'\n'/; }"
  elif [[ -n "$_globalifs" ]]; then
    row "probe-self:no-pipe-into-grep-q" FAIL "this probe sets a global IFS, which changes the join in \"\${declared_series[*]}\" and breaks the runbook-citations membership test: ${_globalifs//$'\n'/; }"
  else
    row "probe-self:no-pipe-into-grep-q" PASS "no producer piped into a quiet grep; no global IFS assignment"
  fi
else
  row "probe-self:no-pipe-into-grep-q" FAIL "PROBE_SELF unset or unreadable, so this probe cannot check itself -- a self-check that cannot run is not a check"
fi

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
    ratified_n=$(spec_seq_count invariants)
    pending_n=$(spec_seq_count invariants_pending_ratification)
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
    # "$nv_test" is passed so a FAIL belonging to a SIBLING test cannot certify
    # this mutation as detected. Computed once: calling the classifier twice
    # risked the two calls disagreeing, and it is the verdict that goes in the
    # evidence string.
    nv_verdict=$(classify_mutation_result "$nv_out" "$nv_test")
    case "$nv_verdict" in
      DETECTED)              nv_proven=$((nv_proven+1)) ;;
      *)                     nv_broken="${nv_broken} ${nv_test}:${nv_verdict}" ;;
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
prop_n=$(grep -rho 'func TestProperty[A-Za-z0-9_]*' --include='*_test.go' . 2>/dev/null | sort -u | wc -l | tr -d ' ')
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
# `[a-z_]*` stops at the first DIGIT, so `//go:build e2e` yielded the tag `e`.
# Every downstream use then looked for `-tags=e`, and the row named a tag that
# does not exist in the repo. Digits belong in the class: build tags are
# [A-Za-z0-9_.] and `e2e` is the single most common integration tag there is.
# `*` matches ZERO characters, so a constraint starting outside the class --
# `//go:build !unit` -- matched the bare `go:build ` prefix, awk emitted an
# EMPTY line, and `sort -u` sorts the empty string FIRST, so `head -1` took it
# and real_tag came back "". Widening the class fixed `e2e` and left that.
# `+` requires at least one character, so a negated leading constraint simply
# does not match instead of winning. Empty lines are dropped as well, because
# a guard that depends on one regex quantifier is a guard with one point of
# failure. NOTE, stated rather than hidden: `//go:build !unit && integration`
# still yields nothing -- the positive tag is not first. That is a narrower
# gap than "empty string wins" and it fails CLOSED (row not emitted), not open.
# Lifted into a FUNCTION so scripts/tests/non-vacuity-selftest.sh can source
# and assert it instead of restating it. A selftest that reimplements the logic
# tests the reimplementation -- this file already learned that with
# classify_mutation_result.
extract_real_tag() {   # extract_real_tag [dir] -> the chosen build tag, or empty
  grep -rhoE 'go:build [A-Za-z0-9_.]+' --include='*_test.go' "${1:-.}" 2>/dev/null | awk '{print $2}' \
    | grep -v '^$' | grep -vE '^(candidate|ignore)$' | sort -u | head -1
}
real_tag=$(extract_real_tag .)
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

# --- 11. profiling (on-demand capture, live endpoint, AND continuous) -------
#
# WHAT THIS ROW MEASURES, AND THE PART IT STILL DOES NOT.
#
# Two of the three signals below are ON-DEMAND: a capture script somebody runs,
# and an endpoint somebody scrapes while the incident is still live.
# dimensions.md §8 makes profiling the FOURTH observability signal and requires
# it CONTINUOUS in production -- always-on sampling shipped to a store with
# retention, so a profile of the process that was slow last Tuesday exists at
# all (Ren, Tune, Moseley, Shi, Rus, Hundt, "Google-Wide Profiling", IEEE Micro
# 30(4), 2010).
#
# This row used to say the continuous half "is not checkable from source" and
# measure only the two on-demand ones. That was true when it was written; it is
# now FALSE, and the cost of leaving it standing was measured, not imagined.
# clc-bitgo-marketdata shipped continuous profiling -- a Pyroscope client
# started from cmd/, mds_profiling_* series, an architecture test holding the
# wiring in place -- and this row still reported "no profiling at all", because
# that repo has neither benchmarks/profile.sh nor net/http/pprof. A repo with
# the STRONGER form failing a row about the absence of the WEAKER one is a row
# people learn to switch off. Five services shipping continuous profiling while
# the org gate reports zero is this file's own recurring failure, one level up:
# the row asserted more than it measured, in the direction that hides work.
#
# What IS checkable was DERIVED from the two repos that implement it
# (clc-binance-marketdata cmd/{aggregator,streamer}/main.go, clc-bitgo-marketdata
# cmd/{api,ingester}/main.go), not invented here:
#
#   1. the profiler is started AT THE COMPOSITION ROOT and its handle is KEPT --
#      `profiler := profiling.StartFromEnv(...)` in non-test cmd/ code, or the
#      underlying `pyroscope.Start(` for a repo that skips the house wrapper.
#      Matching the ASSIGNMENT rather than the identifier is the same discipline
#      the tracing row below had to learn three times: a grep for "pyroscope"
#      anywhere is satisfied by an import line and a comment.
#   2. whether it is actually running is OBSERVABLE in production -- a
#      `*_profiling_enabled` gauge, matched only inside a STRING LITERAL so the
#      paragraph of prose above a metric does not count as the metric.
#
# Both are required, because either alone is fooled: a start site with no gauge
# is a profiler nobody in production can confirm is up, and a gauge with no
# start site is a series that can only ever read 0.
#
# What is STILL not checkable from source, and is therefore still NOT claimed by
# a PASS: that a deployment actually sets the profiler's server address, that
# the uploads land, and that the store retains them. That lives in deployment
# config this repo cannot see -- which is precisely why signal (2) is required
# rather than nice to have: the gauge is what makes it answerable there.
prof_capture=$([[ -f benchmarks/profile.sh ]] && echo yes || echo no)
prof_live=$(grep -rql "net/http/pprof" --include='*.go' . 2>/dev/null && echo yes || echo no)

# -i on the package qualifier only: `profiling.`, `Profiling.`, `pyroscope.`.
prof_cont_sites=$(grep -rnEi ':?=[[:space:]]*(profil|pyroscope)[A-Za-z0-9_]*\.[A-Za-z0-9_]*Start[A-Za-z0-9_]*\(' \
  --include='*.go' --exclude='*_test.go' cmd/ 2>/dev/null | code_lines_only | wc -l | tr -d ' ')
prof_cont_gauge=$(grep -rnE '"[A-Za-z0-9_]*_profiling_enabled' \
  --include='*.go' --exclude='*_test.go' . 2>/dev/null | code_lines_only \
  | grep -oE '"[A-Za-z0-9_]*_profiling_enabled' | tr -d '"' | sort -u | head -1)

# Cross-check against the emitted-metrics manifest when the repo has one. NOT a
# gate here -- observability-contract-checked below already owns "the manifest
# exists and a test reads it", and gating the same fact twice makes one repo's
# missing file red two rows and teaches nobody anything new. Reported, so a
# series that is emitted but undeclared is visible instead of silent.
prof_manifest=$(find . -path ./.git -prune -o -name 'emitted-metrics.*' -print 2>/dev/null | head -1)
if [[ -z "$prof_cont_gauge" ]]; then prof_manifest_note=""
elif [[ -z "$prof_manifest" ]]; then
  prof_manifest_note="; no emitted-metrics.* manifest exists to cross-check it against — see observability-contract-checked"
# -wF, not a bare -q: this row's neighbour (runbook-citations-resolve) already
# had to be fixed once for exactly this, where a SUBSTRING search let
# `svc_units_conserved` resolve against the manifest line for
# `svc_units_conserved_violations_total`. `mds_profiling_enabled` must not be
# satisfied by a declared `mds_profiling_enabled_something`. Underscore is a
# word constituent, so -w is the right boundary here.
elif grep -qwF -- "$prof_cont_gauge" "$prof_manifest" 2>/dev/null; then
  prof_manifest_note="; declared in $prof_manifest"
else
  prof_manifest_note="; NOT declared in $prof_manifest — emitted but invisible to the manifest drift check"
fi

if (( prof_cont_sites > 0 )) && [[ -n "$prof_cont_gauge" ]]; then
  prof_continuous=yes
else
  prof_continuous=no
  if (( prof_cont_sites == 0 )) && [[ -z "$prof_cont_gauge" ]]; then
    prof_cont_why="no profiler started at a composition root in non-test cmd/, and no *_profiling_enabled series in source"
  elif (( prof_cont_sites == 0 )); then
    prof_cont_why="a $prof_cont_gauge series exists but nothing starts a profiler at a composition root in non-test cmd/ — a gauge that can only ever read 0"
  else
    prof_cont_why="$prof_cont_sites composition-root start site(s) in cmd/ but no *_profiling_enabled series in source — nothing in production can tell whether the profiler is actually up"
  fi
fi

prof_ondemand="capture=$prof_capture live=$prof_live"
prof_unproven="NOT proven here: that a deployment sets the profiler's server address, that uploads land, or that the store retains them — deployment config this repo cannot see; $prof_cont_gauge is what answers it in production"
if [[ "$prof_continuous" == yes && "$prof_capture" == yes && "$prof_live" == yes ]]; then
  row "profiling" PASS "CONTINUOUS ($prof_cont_sites composition-root start site(s) in non-test cmd/ keeping the profiler handle, observable as $prof_cont_gauge$prof_manifest_note) AND both on-demand halves ($prof_ondemand). $prof_unproven"
elif [[ "$prof_continuous" == yes ]]; then
  row "profiling" PASS "CONTINUOUS ($prof_cont_sites composition-root start site(s) in non-test cmd/ keeping the profiler handle, observable as $prof_cont_gauge$prof_manifest_note) — the form dimensions.md §8 actually requires. The weaker ON-DEMAND path is incomplete ($prof_ondemand): no ad-hoc capture for an incident that needs a profile of THIS process now. $prof_unproven"
elif [[ "$prof_capture" == yes && "$prof_live" == yes ]]; then
  row "profiling" PASS "capture script + env-gated live endpoint — the ON-DEMAND half only. The CONTINUOUS half dimensions.md §8 requires was CHECKED FOR AND NOT FOUND: $prof_cont_why"
elif [[ "$prof_capture" == yes || "$prof_live" == yes ]]; then
  row "profiling" FAIL "only half of the on-demand path present ($prof_ondemand), and no continuous profiling either: $prof_cont_why"
else
  row "profiling" FAIL "no profiling at all: $prof_ondemand, and $prof_cont_why (claiming 'documented' is the known lie)"
fi

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
# ONE LITERAL, INTERPOLATED — not transcribed into each awk program.
#
# FIVE functions walk the spec with an `inblock` state machine, and a block
# scalar is CONTENT to all five: `notes: >` followed by prose that spells
# `durable_outbox: TBD` must not be read as a declaration. Only `spec_field`
# ever learned that.
#
# The count was "four" until the reconciliation merge of 2026-08-26 and is
# re-measured here rather than carried: `spec_seq_count` joined the walkers on
# fix/registry-gate-block-scalars-and-template-rot, which is a different branch
# from the one that wrote this sentence, so no single diff ever showed both. The
# authority is the interpolation count -- `grep -c 'SPEC_AWK_LIB"'` in this file
# -- which is 5: implemented_test, spec_seq_count, spec_field, driven_symbol,
# driven_keys.
#
# The three readings below are the ORIGINAL measurement, taken on spec_field's
# three siblings at the time -- they are kept exactly as measured and are not
# re-run here. They document why the walker had to be shared; they were never a
# census of the walkers:
#
#   driven_symbol durable_outbox  ->  ESTO-ES-PROSA   (the real value is
#                                     store.OpenDurable, two lines below)
#   driven_keys                   ->  notes durable_outbox durable_outbox
#                                     (a phantom key from the body, and the
#                                     real one listed twice)
#
# The previous attempt "shared" the opener by writing it out a second time in
# awk ERE. That is not sharing: the two had already diverged, and the fix
# reached one of four call sites. This file records the same mistake FIVE times
# for marker rows -- one row repaired while a sibling a few lines away kept the
# bug -- so the sixth repetition is not another per-function patch.
#
# `is_block_header` carries the node-property and colon-optional grammar the
# bash opener in check-registries.sh uses; `block_body` answers "is this line
# inside the block that is open", which is what every caller actually needs.
SPEC_AWK_LIB='
    function txt(  l) { l=$0; sub(/^[[:space:]]+/, "", l); return l }
    # A TAB IN THE INDENT COUNTS AS DEEP, NOT AS ONE CHARACTER. YAML forbids a
    # tab there, so the file is malformed either way -- but the two wrong
    # answers are not equal. Counting it as one character makes a tab-indented
    # BODY measure narrower than its own header, so the block ends early and
    # its prose is read as a declaration: `spec_field scalability
    # partition_key` returned `ESTO-ES-PROSA` over the real value two lines
    # below. Treating it as deep keeps the prose inside the block, which is the
    # fail-CLOSED direction for a function whose job is to return declared
    # values. Reported by agatticelli.
    function indent_of(  m, lead) {
      m = match($0, /[^ \t]/)
      if (m == 0) return 0
      lead = substr($0, 1, m - 1)
      if (lead ~ /\t/) return 9999
      return m - 1
    }
    # THE COMMENT STRIP THE BASH OPENER HAS, WHICH THIS DID NOT. `.*:` reaches a
    # colon inside a trailing `#` comment, so
    #   partition_key: el-valor-real   # ver nota: |
    # was eaten as a block header and the real value disappeared -- spec_field
    # returned empty. Cut outside quotes, for the same reason as next door: a
    # quoted KEY may legitimately contain ` #`.
    function strip_comment(line,   i, c, q, cut) {
      q = ""; cut = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q == "" && (c == "\"" || c == "'"'"'")) { q = c }
        else if (q != "" && c == q) { q = "" }
        else if (q == "" && c == "#" && i > 1 && substr(line, i-1, 1) ~ /[ \t]/) { cut = i; break }
      }
      return (cut ? substr(line, 1, cut - 1) : line)
    }
    function is_block_header(line,  l) {
      l = strip_comment(line)
      return (l ~ /^(.*:[[:space:]]*)?((&[^[:space:]]+|![^[:space:]]*)[[:space:]]+)*[|>]([0-9]+[+-]?|[+-][0-9]*)?[[:space:]]*$/)
    }
'


implemented_test() {
  awk -v key="$1" "$SPEC_AWK_LIB"'
    /^implemented:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      ind = indent_of()
      if (inblk) { if ($0 ~ /^[[:space:]]*$/) next; if (ind > blkind) next; inblk = 0 }
      line = txt()
      if (is_block_header(line)) { blkind = ind; inblk = 1; next }
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
# RECONCILIACION (merge de fix/registry-gate-block-scalars-and-template-rot):
# aca chocaron DOS FUNCIONES DISTINTAS, no dos versiones de una. grep_x viene de
# la linea de comment-stripping y lo usan ci-runs-integration-lane,
# changed-line-coverage, artifact-provenance y secret-scan-all-triggers;
# spec_seq_count viene de esta rama y le da conciencia de block scalars al conteo
# de entradas del spec. Se quedan las dos. Git las marco en conflicto solo porque
# ambas ramas insertaron en el mismo punto, delante de spec_field().
grep_x() {   # grep_x [grep-flags...] <extended-regex> <path>... -> matching FILES
  local flags=()
  # `--` ENDS THE FLAGS. Without this, a pattern that legitimately starts with a
  # dash is eaten by the loop and never reaches grep: `grep_x -- '-fuzz=' $wf`
  # consumed BOTH `--` and `-fuzz=` as flags, so the pattern position fell to a
  # path and the call returned empty -- a row silently reporting "not found" for
  # something present. Reproduced on this tree: `grep_x -- '-fuzz='` returned
  # nothing where `grep_x 'fuzz='` returned the file. Reported by fd1az.
  while [[ "${1:-}" == -* ]]; do
    if [[ "$1" == "--" ]]; then shift; break; fi
    flags+=("$1"); shift
  done
  local pat="$1"; shift
  # `stripped` is LOCAL. It is a new variable in this helper and there is
  # another `stripped` at top level further down; a leaked global would have
  # them share storage in a 2000-line script under `set -u`. Benign today
  # because that one is assigned immediately before use, which is exactly the
  # kind of "benign today" that stops being true in a later edit.
  local f stripped
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Not a pipe into `grep -q`: see the SIGPIPE/pipefail note at the series
    # contract below. This helper is the most-called line in the probe, so an
    # intermittent 141 here would move ANY row, not one.
    stripped=$(sed 's/#.*$//' "$f" 2>/dev/null || true)
    if grep -qE "${flags[@]+"${flags[@]}"}" -- "$pat" <<<"$stripped"; then
      printf '%s\n' "$f"
    fi
  done < <(grep -rlE "${flags[@]+"${flags[@]}"}" -- "$pat" "$@" 2>/dev/null || true)
}

# spec_seq_count counts the ENTRIES of a top-level sequence in the spec:
#
#   spec_seq_count invariants   ->  how many `- ` items `invariants:` declares
#
# LIFTED INTO A FUNCTION so the selftest can assert it directly, the same
# reason extract_real_tag and spec_field were. It was two inline awks that
# counted dashed lines with no block awareness at all -- sharing the walker had
# reached four of the six awks that read this file, and these were the other
# two. (That "six" counts awk PROGRAMS at the time of this change, before the
# two below were folded into this one function. Today the walker is shared by
# FIVE functions -- the authority is `grep -c 'SPEC_AWK_LIB"'` in this file, not
# this sentence, which is kept as the record of why the lift happened.)
# A block scalar inside an entry then inflated the count with its own
# prose: measured on valid YAML with ONE invariant whose `notes: |` body lists
# two bullet points, `ratified_n` reported 3. The row's evidence then claims
# more ratified invariants than the spec declares -- an over-count in the
# direction that flatters. Reported by agatticelli.
spec_seq_count() {   # spec_seq_count <top-level-key> -> number of `- ` items
  awk -v block="$1" "$SPEC_AWK_LIB"'
    $0 ~ "^" block ":" {f=1;next}
    f && /^[a-z_]+:/ {f=0}
    f {
      ind = indent_of()
      if (inblk) { if ($0 ~ /^[[:space:]]*$/) next; if (ind > blkind) next; inblk = 0 }
      if (is_block_header(txt())) { blkind = ind; inblk = 1; next }
      if ($0 ~ /^[[:space:]]*-[[:space:]]/) c++
    }
    END{print c+0}' "$SPEC" 2>/dev/null
}

spec_field() {
  awk -v block="$1" -v key="$2" "$SPEC_AWK_LIB"'

    $0 ~ "^" block ":" { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      ind = indent_of()
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
      if (is_block_header(line)) {
        blkind = ind; inblk = 1; body = ""; want = (line ~ "^" key ":")
        next
      }
      if (line ~ "^" key ":") {
        sub("^" key ":[[:space:]]*", "", line)
        # STRIP THE TRAILING COMMENT FROM THE VALUE TOO. Only here, on the
        # scalar path: inside a block BODY a `#` is content and must survive.
        # Without this the row got `el-valor-real   # ver nota: |` and compared
        # a declaration against a string carrying its own annotation.
        line = strip_comment(line)
        sub(/[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line)
        print line; exit
      }
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
  awk -v key="$1" "$SPEC_AWK_LIB"'
    /^driven:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      ind = indent_of()
      if (inblk) { if ($0 ~ /^[[:space:]]*$/) next; if (ind > blkind) next; inblk = 0 }
      line = txt()
      if (is_block_header(line)) { blkind = ind; inblk = 1; next }
      if (line ~ "^" key ":") { sub("^" key ":[[:space:]]*", "", line); gsub(/^"|"$/, "", line); print line; exit }
    }
  ' "$SPEC" 2>/dev/null
}

# driven_keys lists every key declared under `driven:`.
driven_keys() {
  awk "$SPEC_AWK_LIB"'
    /^driven:/ { inblock=1; next }
    inblock && /^[a-z_]+:/ { inblock=0 }
    inblock {
      ind = indent_of()
      if (inblk) { if ($0 ~ /^[[:space:]]*$/) next; if (ind > blkind) next; inblk = 0 }
      line = txt()
      if (is_block_header(line)) { blkind = ind; inblk = 1 }
      if ($0 ~ /^[[:space:]]+[a-z_]+:/) { sub(/:.*$/, "", line); print line }
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

# THE SECOND WIRING SHAPE: a process-wide TracerProvider instead of a threaded
# tracer.
#
# `tracer_sites` above looks for a tracer THREADED through constructors --
# `hub.SetTracer(...)`, `WithTracer(...)`, `Tracer:` in a struct literal. That
# is one of the two ways OTel is used. The other installs a GLOBAL provider once
# at boot -- `otel.SetTracerProvider(tp)` inside a setupTracing() the entrypoint
# calls -- and then instruments with otelhttp/otelgrpc, which read the global.
# Nothing is ever passed to anything, so the threading grep counts zero sites and
# the row fell through to "cmd/ names a tracer but never passes or assigns it".
#
# Measured on clc-bitgo-marketdata, where that verdict is FALSE:
# cmd/api/main.go calls setupTracing(ctx, "mds-api") and keeps its shutdown func,
# obs.SetupTracing calls otel.SetTracerProvider(tp) plus SetTextMapPropagator,
# and serve() wraps the whole router in otelhttp.NewHandler. The tracing is
# wired; only the pattern was unrecognised.
#
# This false positive is expensive out of proportion to itself. It is the SAME
# dimension that was just gated on clc-binance-marketdata, WHERE THE HOLE WAS
# REAL -- and a row that reds a correctly-wired service is a row people learn to
# discount, which is exactly how the genuinely-unwired one gets waved through.
# Same lesson the mechanisms-driven row learned about inlining, in the other
# direction.
#
# TWO signals, both required, because either alone is fooled:
#   - cmd/ KEEPS the result of a tracing bootstrap call (the shutdown func), not
#     merely names one -- the same assignment discipline the threaded shape
#     needed, so a helper that is defined and never called does not count; and
#   - the codebase actually installs the global provider in non-test code, so a
#     `setupTracing` that configures nothing does not count either.
#
# Like the branch above this is an EXISTENCE check over the entrypoints: it
# cannot prove the call is reached in production, and the evidence says so
# rather than claiming "installed".
global_tp_install=$(grep -rn --include='*.go' --exclude='*_test.go' \
  'otel\.SetTracerProvider(' cmd/ internal/ pkg/ 2>/dev/null | code_lines_only | wc -l | tr -d ' ')
# The callee must be a BOOTSTRAP -- a verb (setup/init/new/start/configure/...)
# next to "trac", in either order: `setupTracing(...)` or `tracing.New(...)`.
#
# The first version of this pattern accepted any assigned call whose name
# contained "trac", and mutation testing caught it before it shipped: deleting
# both `tracingShutdown, err := setupTracing(ctx, ...)` calls from cmd/ left the
# row GREEN at 2 sites, because `if err := tracingShutdown(shutdownCtx)` -- the
# leftover USE of the handle -- still matched. A row that survives the deletion
# of the thing it checks is decoration, which is the exact defect this row was
# being fixed for.
cmd_tracing_boot=$(grep -rnE --include='*.go' --exclude='*_test.go' \
  '^[[:space:]]*[A-Za-z_][A-Za-z0-9_,[:space:]]*(:=|=)[[:space:]]*(([A-Za-z0-9_]+\.)?([Ss]etup|[Ii]nit|[Nn]ew|[Ss]tart|[Cc]onfigure|[Bb]ootstrap|[Ee]nable|[Ii]nstall|[Pp]rovide)[A-Za-z0-9_]*[Tt]rac[A-Za-z0-9_]*|[A-Za-z0-9_]*[Tt]rac[A-Za-z0-9_]*\.([Ss]etup|[Ii]nit|[Nn]ew|[Ss]tart|[Cc]onfigure|[Bb]ootstrap|[Ee]nable|[Ii]nstall|[Pp]rovide)[A-Za-z0-9_]*)\(' \
  cmd/ 2>/dev/null | code_lines_only | wc -l | tr -d ' ')
# Named only in the evidence, never required: a gRPC-only service uses otelgrpc,
# a worker neither, and demanding one of them would red a correct repo for the
# transport it happens to speak.
global_tp_instr=$(grep -rn --include='*.go' --exclude='*_test.go' \
  'otelhttp\.New\|otelgrpc\.\|otelgin\.\|otelecho\.\|otelfiber\.' cmd/ internal/ pkg/ 2>/dev/null | code_lines_only | wc -l | tr -d ' ')
# `${x:+...}` fires on the STRING "0", so the first draft of the evidence read
# "with 0 instrumentation site(s) reading that global" -- a clause asserting
# something over a count of nothing, which is the evidence-free-PASS shape the
# row() guard exists to catch, smuggled in as prose. Zero is worth SAYING, not
# hiding: a global provider nobody instruments against creates no spans through
# it. Not a FAIL, because a repo can call otel.Tracer("x").Start directly and
# reding it would be a new false positive of exactly the kind being fixed here.
if (( ${global_tp_instr:-0} > 0 )); then
  global_tp_instr_note=", with $global_tp_instr otelhttp/otelgrpc instrumentation site(s) reading that global"
else
  global_tp_instr_note=", but NO otelhttp/otelgrpc instrumentation site reading that global was found — if nothing else calls otel.Tracer(...).Start directly, the installed provider creates no spans"
fi
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
elif (( ${global_tp_install:-0} > 0 && ${cmd_tracing_boot:-0} > 0 )); then
  row "tracing-wired-in-prod" PASS "GLOBAL TracerProvider shape: $cmd_tracing_boot non-test cmd/ line(s) keep the result of a tracing bootstrap call, and $global_tp_install non-test otel.SetTracerProvider( call site(s) install the provider they read$global_tp_instr_note — existence only, same as the threaded shape above: this proves the wiring EXISTS in the entrypoints, not that it is reached in production; only a contract test exercising the entrypoint can"
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
# A vulnerability count is a property of the TOOLCHAIN, not of this code, so a
# row that prints a number without naming the Go version is not a measurement.
# Measured 2026-08-23 on clcsolutions/okx-marketdata, SAME TREE:
#   go1.26.0 -> 22 called | go1.26.5 -> 6 called | go1.26.6 -> 0 called.
# Two different readers of that surface BOTH got it wrong -- one reported "6"
# (its laptop's version), one concluded "false alarm" (0 under the newest).
# The number that matters is the one under the toolchain CI INSTALLS, and these
# repos derive that from go.mod's literal and feed it to setup-go. So the row
# names what ran AND flags a mismatch with what go.mod pins: a local scan on a
# different toolchain does not describe what ships.
# Lifted into a FUNCTION for the same reason extract_real_tag was: the selftest
# asserts it directly. Counts workflows that DEFINE the job or invoke it with a
# real `uses:`, never files that merely MENTION the string -- a comment naming
# secret-scan used to flip this row to PASS with nothing wired.
count_secret_scan_workflows() {   # <workflows-dir> -> count
  # THE COMMENT MUST BE STRIPPED BEFORE MATCHING, not merely anchored away.
  #
  # The `^` anchor only rejects a comment that owns its LINE. It does nothing
  # about a TRAILING one, and `.*secret-scan` happily reaches across into it:
  #
  #   - uses: actions/checkout@v4  # secret-scan runs in ci.yaml, not here
  #
  # is a real `uses:` line for a DIFFERENT action, and it was counted as a
  # secret-scan mechanism. A file that says in prose that it does NOT scan was
  # scored as scanning -- the reading is exactly inverted. Reported by
  # agatticelli on kraken-marketdata#11.
  #
  # Found at the reconciliation merge (2026-08-26) and worth recording HOW,
  # because it is the argument for merging tests and code from different
  # branches instead of picking one: the fixture that catches this came from
  # fix/registry-gate-block-scalars-and-template-rot, the implementation came
  # from fix/probe-defects-and-shared-selftest, and NEITHER BRANCH HAD BOTH.
  # The test passed on its own branch (no implementation to run) and the
  # implementation passed on its own branch (no fixture with a trailing
  # comment). Only together do they go red.
  #
  # grep_x, which strips comment bodies before matching, is the fix the rest of
  # this file already uses for the same class -- sbom, artifact-provenance,
  # ci-runs-integration-lane and changed-line-coverage all had this defect.
  grep_x '^[[:space:]]*-?[[:space:]]*uses:.*secret-scan|^[[:space:]]+secret-scan:' "$1" 2>/dev/null | wc -l | tr -d ' '
}

# A ROW THAT LOOKS FOR A MARKER MUST LOOK AT WHAT THE FILE DOES, NOT AT WHAT IT
# SAYS ABOUT ITSELF. This exact defect has now been repaired FIVE times in this
# file -- artifact-provenance, secret-scan-all-triggers, ci-runs-integration-lane,
# and then sbom and changed-line-coverage -- and every one of the first three
# fixes landed on one row while a sibling a few lines away kept the bug. Two of
# those siblings were caught in review, on the branch whose whole subject was
# this class.
#
# Patching row six the same way would be the same mistake a sixth time, so the
# stripping is a FUNCTION and the rows call it. A new row that greps for a
# marker either calls this or is wrong by construction.
#
# `#` comment bodies are stripped: YAML, Makefiles and shell all use it. `#`
# inside a quoted string is not honoured, deliberately -- a marker that appears
# ONLY inside such a string is vanishingly rare beside the failure this
# prevents, and for a gate the safe direction is FAIL.
#
# Only files that matched at all are re-read, so this costs one extra pass over
# the few files that already hit.
# NOTA DE LA RECONCILIACION (2026-08-26): aca habia una SEGUNDA definicion de
# grep_x, identica a la de arriba salvo que su bucle de flags NO cortaba en `--`.
# La trajo fix/probe-block-scalars-and-comment-stripping y la de arriba viene de
# fix/probe-defects-and-shared-selftest; como cada rama la inserto en un punto
# distinto del archivo, git mergeo LAS DOS sin marcar conflicto. En bash gana la
# ULTIMA, asi que la version activa era la debil y `grep_x -- '-fuzz=' $wf` se
# comia `--` y `-fuzz=` como flags: devolvia vacio y ci-runs-fuzz reportaba
# "NO workflow invokes any of them" en cualquier repo que fuzzee directo.
# Reproducido antes de borrarla, sobre un workflow que SI fuzzea:
#   debil  -> []                (+ "grep: --: No such file or directory")
#   fuerte -> [.../pr.yaml]
# Un merge limpio que compila no es un merge que gatea: esto no genero ni un
# conflicto. Se elimino la duplicada y quedo la que maneja `--`.

toolchain_note() {
  local ran pinned
  ran=$(go env GOVERSION 2>/dev/null || echo "unknown")
  pinned=$(awk '/^go [0-9]/{print "go"$2; exit}' go.mod 2>/dev/null || echo "")
  if [[ -n "$pinned" && "$ran" != "$pinned" ]]; then
    printf '(ran under %s, but go.mod pins %s -- CI installs the PINNED one, so this count may not describe what ships)' "$ran" "$pinned"
  else
    printf '(under %s)' "$ran"
  fi
}

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
    row "vuln-scan" PASS "govulncheck: 0 called vulnerabilities $(toolchain_note)"
  elif found=$(grep -m1 -E 'affected by [0-9]+ vulnerabilit' <<<"$vout"); then
    row "vuln-scan" FAIL "$found $(toolchain_note)"
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

  # Counted FILES THAT MENTION the string, not workflows that run the job -- so a
  # comment naming secret-scan flipped this row to PASS with nothing wired. Caught
  # 2026-08-23 on kraken-marketdata: a comment added by the very branch installing
  # the standard turned this row FAIL -> PASS. A checker cannot tell a citation
  # from a tombstone unless it is made to look for the mechanism, so this now
  # requires a job DEFINITION (`secret-scan:`) or a real `uses:` invocation.
  sc=$(count_secret_scan_workflows "$wf")
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
# clcsolutions/ci@main 2026-08-24 -- image-push.yaml:145 is the only artifact
# deletion in ALL 27 reusable workflows there, and image-push.yaml:55 plus
# sbom.yaml:52 are the only `-image` consumers. (I had grepped six workflows;
# fd1az re-derived it across all 27 independently, which is the number that
# belongs here.) A NEW deleting workflow added later would be invisible to this
# row. The row is scoped per
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
  # `producer | grep -q PATTERN` under `set -o pipefail` is a race: -q exits at
  # the first match and closes the pipe, and if the producer is still writing it
  # takes SIGPIPE (141), which pipefail then reports as the pipeline's status --
  # turning a MATCH into a FAIL, nondeterministically.
  #
  # [WITHDRAWN] "It does not bite while the input fits the 64KB pipe buffer (this
  # [WITHDRAWN]  repo's four workflows are ~683 lines, so the producer always
  # [WITHDRAWN]  finishes first)"
  # [WITHDRAWN] "I could not reproduce it in 40 runs across two trees, so the
  # [WITHDRAWN]  flake itself stays UNCONFIRMED"
  #
  # Both are withdrawn as of 2026-08-25. The sibling runbook-citations row had the
  # same shape with a BUILTIN producer, and on clcsolutions/binance-marketdata's
  # real manifest it reported a DIFFERENT set of "nonexistent" series on MOST
  # runs, every one of them declared. Aggregated over five samples that day:
  # 207 of 290 runs, ~71%, no sample below 13/30 and the largest 82/100. The rate
  # tracks machine load; it is not "sometimes".
  #
  # THE 64KB FIGURE WAS NOT A SAFETY MARGIN. Threshold is not a function of input
  # size alone: it depends on the producer (a shell builtin in a forked subshell
  # races from the first element; an external command may buffer first), on how
  # many stages sit between producer and reader (an intervening `sed` absorbs a
  # sub-64KB stream and hides the race entirely), on where the match falls, and on
  # load. A first pass measured a two-stage external producer clean at 9KB and
  # racy at 72KB and concluded the boundary was the 64KB pipe buffer; a second
  # measured the same shape racy at 21-35KB. NEITHER READING WAS WRONG -- the
  # first pass simply never sampled 21-45KB. The data lie on one monotone curve;
  # only the conclusion drawn from the gap was wrong.
  #
  # Match position is the one absolute here, and it was measured rather than
  # assumed: a match on the LAST line never races (0/300 at 182KB, where a
  # first-line match gives 300/300), because grep reads to EOF and the producer
  # finishes.
  #
  # That is the whole lesson. Deciding per row whether THIS instance is safe is
  # the reasoning that produced "UNCONFIRMED" the first time, and it was wrong.
  # So the rule is unconditional and not a judgement call: read the producer into
  # a variable, or use a here-string. Never pipe a producer into `grep -q`. That
  # rule is now enforced mechanically by the `probe-self:no-pipe-into-grep-q` row
  # below, not just asserted here.
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
    # A `declared_blob=$(printf '%s\n' "${declared_series[@]}")` used to sit
    # here, under a comment explaining that it was built once and deliberately
    # not piped into `grep -q`. BOTH ARE GONE, and the reason is worth keeping,
    # because the variable outlived its reader by a whole merge.
    #
    # Two branches fixed the SAME SIGPIPE race in THIS row by different means:
    # fix/probe-defects-and-shared-selftest introduced this blob plus a
    # `grep -qx "$m" <<<"$declared_blob"` membership test, and
    # fix/probe-sigpipe-pipefail-membership replaced the test with the
    # subprocess-free array join now at the `[[ " ${declared_series[*]-} " ... ]]`
    # line below. The reconciliation merge kept the array join -- the stronger
    # fix -- but kept this branch's ASSIGNMENT too, because the two edits touched
    # different lines and git had no conflict to raise. The result compiled, cost
    # a subshell per invocation, and was read by nothing.
    #
    # That is the same defect class as the duplicated `grep_x` this merge also
    # had to repair: a clean three-way merge silently composing two halves of two
    # different fixes. The dangerous part was never the wasted subshell -- it was
    # this comment, which sat in the file's longest SIGPIPE explanation asserting
    # that the safe-membership mechanism lived HERE. Anyone repairing this row
    # would have read it as load-bearing and reasoned from it. A comment that
    # describes a variable nothing consumes is worse than no comment: it is a
    # false map of the gate.
    #
    # The live membership test, and the full argument for it, are on the
    # `[[ " ${declared_series[*]-} " == *" $m "* ]]` line further down.
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
      # NOT `printf ... | grep -qx "$m"`. Under this file's `set -o pipefail` that
      # pipeline is the SIGPIPE race the artifact-provenance row above describes --
      # and here it is CONFIRMED, because the producer is a BUILTIN in a forked
      # subshell, which races from the very first element instead of buffering first.
      # `grep -q` exits at the first match and closes the pipe, printf takes SIGPIPE
      # (141), pipefail reports the pipeline as failed, and a series that IS declared
      # gets reported missing.
      #
      # Measured on clcsolutions/binance-marketdata 2026-08-25, unchanged tree, real
      # manifest and RUNBOOK. THE RATE IS LOAD-DEPENDENT, so it is given as a spread
      # and not as one number: four samples that day gave 65/100, 24/30, 23/30 and
      # 13/30 pre-fix -- between a third and two thirds of runs. Post-fix: 0/100 and
      # 0/30, every sample. In the 100-run sample, 23 DISTINCT series were reported
      # nonexistent across runs and all 23 are in the manifest (56 declared, 28
      # cited). An earlier draft of this comment said "23 of 30 ... and 15 of 30 in
      # an independent replication"; the 15 was never measured by anyone and is
      # withdrawn. A wrong number in a comment about a gate that reports a different
      # answer every run is the exact failure this row is being repaired for.
      #
      # Isolated, match at the FIRST element: ~1-5/100 at 10 elements, ~5-9/100 at
      # 100, ~38-51/100 at 2000, 100% at 20000, always exit 141. Match at the LAST
      # element: 0/100 -- grep reads to EOF so printf finishes. A small manifest does
      # not make this safe, only rarer.
      #
      # A gate that reports a different finding every run trains people to re-run it
      # until it is green, which is worse than no gate at all.
      #
      # The joined-array membership test has no pipeline, no subprocess and no race.
      # The delimiter is safe STRUCTURALLY, not by convention: `declared_series` is
      # built by `awk '{print $NF}'`, which yields a whitespace-delimited field, so an
      # element cannot contain a space or tab. The surrounding spaces make it an
      # exact-token test rather than the substring search this row's comment above
      # already had to fix once.
      #
      # It is also a LITERAL test where `-x` was a REGEX one, and that is a real
      # semantic difference, not a no-op. Three inputs make the two disagree:
      # `$m` containing `.` or `^` (regex to grep, literal here), and an array element
      # containing a space (impossible per the awk argument above). All three are
      # unreachable with today's extractor -- but note the extractor at the mapfile
      # above is `[a-zA-Z_][a-zA-Z0-9_]*`, which admits UPPERCASE; it is the DATA that
      # is all lowercase, not the code. No uppercase letter is a metacharacter, so the
      # conclusion holds either way. Glob metacharacters in `$m` are already inert
      # because `" $m "` is quoted inside `[[ ]]`; verified with `*` and `?`.
      #
      # `[*]-` and not `[*]`: on bash before 4.4 an EMPTY array under `set -u` is
      # treated as unbound, and this file's guard is `BASH_VERSINFO[0] < 4`, so
      # 4.0-4.3 gets in. PURELY DEFENSIVE -- no live bug. Two drafts of this comment
      # got the rationale wrong and both are withdrawn: it does not prevent an abort.
      # Review established that on 4.4+ the line IS reached with an empty manifest and
      # does NOT abort (`printf '%s\n'` with no arguments still emits a newline, so
      # `series_prefixes` has one element and the guard passes), while on 4.0-4.3 the
      # process substitution feeding `mapfile -t series_prefixes` dies first and the
      # line is UNREACHABLE. In the version where it is reached it does not abort; in
      # the version where it would abort it is not reached. The `-` costs nothing and
      # removes the question. Semantics checked on bash 5.3.15, the real runtime, and
      # on 3.2.57 as a PROXY for pre-4.4 nounset behaviour only -- 3.2 is NOT
      # supported here (no `mapfile`; the version guard exits first). NOBODY HAS
      # TESTED 4.0-4.3: none was available. That range is reasoned about, not measured.
      #
      # ONE COUPLING THIS TEST HAS AND THE OLD ONE DID NOT: `"${arr[*]}"` joins
      # with the FIRST CHARACTER OF IFS, not with a space. This file assigns IFS
      # ZERO times outside the `IFS= read` prefix form (which is scoped to its
      # own command), so the join is a space and the test is exact. If anyone
      # ever sets a global IFS above this line, this row starts reporting
      # declared series as missing -- the exact failure it was just repaired for.
      # This is CHECKED MECHANICALLY by the `probe-self:no-pipe-into-grep-q` row
      # near the lint section, which fails on a global IFS assignment as well as
      # on a piped `grep -q`. An earlier draft of this comment claimed the check
      # was mechanical when it was a grep someone had run by hand once; review
      # caught that, and the honest repair was to build the check rather than to
      # soften the sentence.
      #
      # INDEPENDENT CONFIRMATION, kept from the parallel fix that a second
      # session wrote for this same line (branch
      # fix/probe-profiling-continuous-and-tracing-global, commit 654e723).
      # It reached the same diagnosis from a different observation and named a
      # DIFFERENT pair of series -- clcbinance_bar_duplicates_total and
      # clcbinance_bar_gap_days_total -- where the run that motivated the
      # reconciliation named clcbinance_bar_duplicates_total and
      # clcmd_upstream_invalid_venue_items_total. That the reported set varies
      # across observers is the strongest evidence the defect is the race and
      # not a real manifest gap. That session's repair was a here-string
      # (`grep -qxF -- "$m" <<<"$(printf ...)"`); measured over 300 runs on the
      # binance tree it is also 0/300, so it was correct. This joined-array form
      # is kept over it because it forks no subshell at all and because the
      # `probe-self:no-pipe-into-grep-q` row can enforce it mechanically. The
      # here-string form is explicitly QUIET under that row (selftest case
      # "here-string into grep -q"), so neither fix would have broken the other.
      [[ " ${declared_series[*]-} " == *" $m "* ]] || { bad=$((bad+1)); missing="${missing} $m"; }
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
# RECONCILIACION (merge de fix/probe-defects-and-shared-selftest): este bloque
# COMPONE dos arreglos independientes que chocaron aca. No es "gano uno".
#   - la clausura de prerequisitos de make (abajo) viene de esta rama y quita un
#     FAIL FALSO medido en kraken-marketdata, donde el fuzz corre via `make verify`;
#   - el `grep_x` de la condicion viene de fix/probe-block-scalars-and-comment-stripping
#     y quita el defecto opuesto: un COMENTARIO que menciona `-fuzz=` compraba la fila.
# Quedarse con uno solo reintroduce el defecto del otro, en direcciones opuestas.
# A target whose RECIPE fuzzes is not the only way a workflow runs the fuzz lane:
# `verify: lint race fuzz` + a job that runs `make verify` is the same lane, and
# the recipe-only matcher called that "NO workflow invokes any of them".
# Measured on kraken-marketdata 2026-08-23: fuzz ran on every PR and this row
# read FAIL. A false FAIL is not the safe direction -- it trains people to widen
# the gate until it is gone. So expand UPWARD through prerequisite chains to a
# fixed point (bounded: Makefiles are shallow, and an unbounded loop in a probe
# is its own outage).
# Two traps, both caught by mutating this loop instead of reading it:
#  - `awk -v seeds="$multiline"` dies with "newline in string"; awk -v processes
#    escapes and rejects a literal newline. Seeds travel space-separated.
#  - `.PHONY: fuzz verify` parses as a rule whose prerequisites include `fuzz`,
#    so the closure "reached" .PHONY and the row proposed `make .PHONY`. Special
#    dot-targets are excluded: they are declarations, not lanes.
# make JOINS `\`-continued lines; the closure read one PHYSICAL line, so
# `verify: lint \` + `fuzz \` + `race` dropped verify and everything above it.
# Measured on a synthetic Makefile: seed [fuzz], closure [fuzz] where the
# correct answer is [fuzz verify ci]. Both that and `::` rules landed as the
# false FAIL this block was written to remove, and both were silent.
fold_makefile() { sed -e :a -e '/\\$/N; s/\\\n//; ta' Makefile 2>/dev/null; }

fuzz_reachable="$fuzz_make_targets"
for _ in 1 2 3 4 5 6; do
  # shellcheck disable=SC2086  # deliberate: collapse the newline-separated
  # seed list into one space-separated -v value; awk -v rejects a literal
  # newline ("newline in string").
  more=$(fold_makefile | awk -v seeds="$(echo $fuzz_reachable | tr '\n' ' ')" '
    BEGIN { n = split(seeds, sd, /[ \t]+/); for (i = 1; i <= n; i++) if (sd[i] != "") want[sd[i]] = 1 }
    /^[a-zA-Z0-9_.\-]+[ \t]*::?[^=]/ {
      # Double-colon rules split to an EMPTY prerequisite field on a naive
      # split(":"), so `verify:: fuzz lint` dropped verify and everything above
      # it -- the exact false FAIL this block exists to remove. Take everything
      # after the FIRST colon run instead of trusting field 2.
      t = $0; sub(/[ \t]*::?.*$/, "", t)
      if (t ~ /^\./) next
      rest = $0; sub(/^[^:]*::?[ \t]*/, "", rest)
      m = split(rest, pq, /[ \t]+/)
      for (j = 1; j <= m; j++) if (pq[j] != "" && (pq[j] in want)) print t
    }' 2>/dev/null | sort -u)
  new_reach=$(printf '%s\n%s\n' "$fuzz_reachable" "$more" | sort -u | sed '/^$/d')
  [[ "$new_reach" == "$fuzz_reachable" ]] && break
  fuzz_reachable="$new_reach"
done
fuzz_ci_evidence=""
# grep_x, NOT grep: a workflow COMMENT mentioning `-fuzz=` bought this row
# outright, and the row's whole claim is that fuzzing is EXECUTED in CI.
# Needed grep_x's `--` handling too, since the pattern starts with a dash.
if [[ -n "$(grep_x -- '-fuzz=' $wf)" ]]; then
  fuzz_ci_evidence="a workflow step fuzzes directly"
else
  while IFS= read -r mt; do
    [[ -z "$mt" ]] && continue
    if grep -rqE "make (--[a-z-]+ )*$mt( |\$|\")" $wf 2>/dev/null; then
      fuzz_ci_evidence="a workflow runs 'make $mt'"; break
    fi
  done <<<"$fuzz_reachable"
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
  # COMMENTS ARE STRIPPED BEFORE MATCHING. Found on re-canary 2026-08-23: a
  # comment written INTO pr.yaml, explaining that the lane runs with
  # `-tags=chaos`, satisfied this row for four commits -- prose about the gate
  # bought the gate, in the file the prose was describing. Same defect this
  # probe already fixed for artifact-provenance and secret-scan-all-triggers;
  # this sibling row was missed. Reproduced before fixing: a workflow whose
  # ONLY mention of the tag is a comment gave PASS.
  il_hits=$(grep -rl -- "-tags=$real_tag\|tags: *$real_tag" Makefile $wf 2>/dev/null || true)
  il_real=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # drop comment bodies, then look again in what is left
    stripped=$(sed 's/#.*$//' "$f" 2>/dev/null || true)
    if grep -q -- "-tags=$real_tag\|tags: *$real_tag" <<<"$stripped"; then
      il_real="$f"; break
    fi
  done <<<"$il_hits"
  if [[ -n "$il_real" ]]; then
    row "ci-runs-integration-lane" PASS "'$real_tag' lane wired into ${il_real#./}"
  elif [[ -n "$il_hits" ]]; then
    row "ci-runs-integration-lane" FAIL "'$real_tag' appears ONLY inside comments ($(echo "$il_hits" | tr '\n' ' ' | sed 's/ *$//')) — prose about a lane is not a lane"
  else
    row "ci-runs-integration-lane" FAIL "'$real_tag' lane exists but no make target or CI job runs it"
  fi
fi
# The probe VENDORS ITSELF into scripts/, and the line you are reading contains
# the string "changed-line" -- so the old matcher passed this row in every repo
# that installed the standard, by finding its own source. A gate that certifies
# itself is worse than an absent one: it reports green for the exact repos that
# just adopted it and have wired nothing yet. Measured on kraken-marketdata
# 2026-08-23: the only matching file was scripts/verify-standard.sh.
# The probe's own file is therefore excluded, and the row now carries the list
# of files that DID match as its evidence, so a PASS names what wired it.
# Excluding the probe's own copy closed the pure self-reference, but the
# `scripts` arm still passed on a file's mere PRESENCE -- a repo that copies in
# changed-line-coverage.sh and wires it into no workflow got a PASS naming that
# script. That is the citation-vs-tombstone trap this same file refuses for
# `fitness-functions`, and two rows in one probe cannot answer the same
# question opposite ways. So the INVOCATION must appear in a workflow or the
# Makefile; a script under scripts/ is corroborating evidence, never the whole
# case.
cl_invoked=$(grep_x 'diff-cover|patch coverage|changed-line' Makefile $wf \
             | grep -vF "$(basename "$PROBE_SELF")" || true)
cl_hits=$(grep_x 'diff-cover|patch coverage|changed-line' Makefile $wf scripts \
          | grep -vF "$(basename "$PROBE_SELF")" || true)
if [[ -n "$cl_invoked" ]]; then
  row "changed-line-coverage" PASS "changed-line signal wired in $(echo "$cl_hits" | tr '\n' ' ' | sed 's/ *$//')"
else
  if [[ -n "$cl_hits" ]]; then
    row "changed-line-coverage" FAIL "a changed-line script exists ($(echo "$cl_hits" | tr '\n' ' ' | sed 's/ *$//')) but NO workflow or Makefile target invokes it — a file with that name is not a measurement"
  else
    row "changed-line-coverage" FAIL "changed-line coverage (every tier's SIGNAL) is measured nowhere — the probe's own vendored copy does not count as wiring"
  fi
fi

# --- 22. reproducibility / operational determinism (restored dimension) -----
# Probe the EFFECT: a revision that CAN be non-empty in the shipped artifact.
# An earlier version passed on the mere presence of the wiring while every image
# CI built shipped revision="" — .dockerignore excluded .git, so -buildvcs had
# nothing to stamp and no --build-arg path existed. That false green is exactly
# what this dimension is now checked against.
if grep -rqE "commit|git_sha|config_version|schema_version|build_info" observability/*.yaml observability/*.md 2>/dev/null; then
  stampable="unknown"
  if [[ -f .dockerignore ]] && grep -qxE '\.git/?' .dockerignore; then
    # TWO DEFECTS IN ONE LINE. Plain `grep`, so a Dockerfile COMMENT bought the
    # row; and the WORD `ldflags` is not a stamp -- `-ldflags="-s -w"` strips
    # symbols and sets nothing, so the image ships revision="" while this row
    # reports the revision as stampable. An `-X <pkg>.<Var>=` assignment is what
    # makes it a stamp, and GIT_SHA stays a separate, sufficient build-arg path.
    if [[ -n "$(grep_x -- '-X[[:space:]=]+[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+=[A-Za-z0-9_${(/.-]' docker/)" ]]; then
      stampable="ldflags"
    elif [[ -n "$(grep_x 'GIT_SHA' docker/)" ]]; then
      stampable="build-arg"
    else
      stampable="no"
    fi
  else stampable="buildvcs"; fi
  case "$stampable" in
    no) row "operational-determinism" FAIL "signals declare a revision but .dockerignore excludes .git and no ldflags path exists — every image ships revision=\"\"" ;;
    *)  row "operational-determinism" PASS "versions surfaced; revision stampable via $stampable" ;;
  esac
else row "operational-determinism" FAIL "Output=F(code,config,state,inputs): the four versions are not surfaced — replay cannot reproduce prod"; fi

# --- 23. load / stress / soak (dimension 25) --------------------------------
#
# THE QUESTION THIS ASKS THAT NO ROW ABOVE ASKS: at what arrival rate does this
# system stop keeping up, and how far is that point from the peak it is
# expected to serve?
#
# The `benchmarks` row (dimension 10, above) does NOT answer it, and the
# difference is mechanical rather than a matter of emphasis. That row runs
# `go test -run='^$' -bench=. -benchtime=10x`: one operation, ten iterations, no
# concurrency, no queue. A system can hold a perfectly flat ns/op while its
# saturation point sits BELOW its expected peak, because saturation is a
# property of contention and of coherency traffic, not of per-operation cost.
# Gunther's Universal Scalability Law (Guerrilla Capacity Planning, 2007) is
# that argument in closed form -- C(N) = N / (1 + a(N-1) + bN(N-1)) -- where the
# serialization coefficient `a` and the crosstalk coefficient `b` are the only
# terms that decide where the throughput curve turns over, and BOTH vanish at
# N=1. A benchmark at N=1 measures neither. That is why a green `benchmarks`
# row has never been evidence about capacity, and why this dimension is
# separate rather than an extra assertion inside that one.
#
# WHY THE ARTIFACT IS A DOCUMENT. The saturation point is only meaningful
# against a hardware shape and an expected peak, and both of those are
# declarations a human owns -- no test can derive them. So dimension 25's
# evidence is benchmarks/load/baseline.md, written by whoever ran the load, and
# the spec's `load_baseline.margin_target` is what that document is scored
# against.
#
# WHICH MEANS THIS ROW IS CHECKED HARDER THAN A TEST-BACKED ONE, not more
# softly. A prose artifact is the easiest thing in this framework to satisfy
# dishonestly: a sentence saying "we never found the saturation point" contains
# the word `saturation`, and a keyword grep is this file's oldest and most
# repeated defect -- `grep -qi "reconcil"` satisfied by a comment saying
# reconciliation is absent, the `mutation` keyword search satisfied by typing
# the word, `grep -rqi "sbom\|syft"` green for weeks in a repo whose sbom job
# had never once succeeded. All three shipped. Three guards separate this row
# from that habit:
#
#   1. FIELD SHAPE, NOT WORD PRESENCE. Every value must sit on a `key: value`
#      line and must START with its number. `saturation point: not measured
#      yet` fails, and so does a paragraph about the saturation point, because
#      neither puts a number where the number belongs.
#   2. THE MARGIN IS COMPARED, NOT READ. The document's headroom is checked
#      against `load_baseline.margin_target` in the spec, so a document
#      recording 1.1x against a declared 3x target is a FAIL naming both
#      numbers -- not a PASS for having a margin line.
#   3. THE MEASUREMENT CARRIES AN AGE, READ FROM INSIDE THE DOCUMENT. Never
#      from the file's mtime: a clone stamps every file with the checkout time,
#      so an mtime freshness check reports a three-year-old baseline as zero
#      days old on every CI runner -- fail-open, silently, on exactly the
#      machine that gates the merge.
#
# WHAT A PASS HERE DOES NOT PROVE, stated plainly rather than left to be
# inferred: that the load test was ever run. This row reads a document a human
# writes, and it cannot distinguish a measured number from a typed one. The
# date, the field shape and the comparison raise the cost of a lie; they do not
# remove it. The honest ceiling is that a CI load lane should WRITE this file,
# at which point the row is reading a machine's output -- that is stage 2 work
# and it is not done here, so nobody should read this row as more than
# "somebody committed a measurement that meets the target, recently".
LOAD_BASELINE="benchmarks/load/baseline.md"
# 30 days, and the number is a policy choice rather than a discovery: a load
# baseline decays because the SYSTEM changes, not because the file ages, and
# nothing here can measure that. A month is short enough that a quarter's worth
# of drift cannot hide behind it and long enough that a repo is not re-running
# load on every release. A repo that genuinely needs a different window changes
# it by declining the dimension with the reason, not by editing this constant
# in its vendored copy -- a threshold edited per repo is a threshold nobody can
# reason about across repos.
LOAD_MAX_AGE_DAYS=30

# load_field reads ONE declared field out of the load baseline document.
#
# The grammar is narrow, and it is written down here rather than left implied:
#
#     [ -*> ] [**] <key> [**] : <value>
#
# A leading bullet, blockquote marker or bold decoration is allowed because
# real markdown carries them; the key matches case-insensitively; everything
# after the FIRST colon is the value; the first matching line in the file wins.
#
# A markdown TABLE CELL is deliberately not a field: `| saturation point |
# 12000 rps |` yields nothing, because a two-cell row has no colon and
# accepting it would mean accepting "the key appears somewhere on a line",
# which is the keyword grep this row exists to refuse.
#
# The key regex is PARENTHESISED before it is embedded. Callers pass
# alternations (`(measured|date)`), and unparenthesised alternation would
# escape the surrounding context entirely -- `\**a|b\**[[:space:]]*:` matches a
# bare `a` anywhere on the line, with no colon required. That is a
# fail-OPEN precedence bug, so the group is applied here where every caller
# gets it rather than in each caller where one will eventually forget.
load_field() { # load_field <key-extended-regex> -> the field's value, or empty
  grep -aiE "^[[:space:]]*[-*>]?[[:space:]]*\**(${1})\**[[:space:]]*:" "$LOAD_BASELINE" 2>/dev/null \
    | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//'
}

# load_margin_norm normalises a headroom expression to "<kind> <number>", so
# the document and the spec's target are COMPARED rather than string-matched.
#
# Two kinds are accepted and they are not interchangeable: `3.2x` is a FACTOR
# over expected peak, `220%` is a PERCENTAGE of it. Coercing one into the other
# would let a measured 1.5x satisfy a declared 120% target, which is arithmetic
# on two different quantities dressed up as a comparison -- so a mismatch is a
# FAIL that says so, never a silent conversion.
#
# ANCHORED AT THE START of the value, which is the whole guard: "aiming for 3x
# eventually" does not normalise, because the number that describes a
# measurement has to BE the measurement rather than a number in a sentence
# about one.
load_margin_norm() { # load_margin_norm <text> -> "factor N" | "percent N" | empty
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if   [[ "$t" =~ ^([0-9]+(\.[0-9]+)?)x ]]; then printf 'factor %s' "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ ^([0-9]+(\.[0-9]+)?)% ]]; then printf 'percent %s' "${BASH_REMATCH[1]}"
  fi
}

# load_age_days turns the document's declared measurement date into a whole
# number of days.
#
# python3, not `date -d`: BSD date (every macOS developer machine running this
# probe) rejects `-d`, and GNU date (every Linux CI runner) rejects `-j -f`, so
# a shell-date implementation is right on exactly one of the two machines that
# matter and silently yields an empty age on the other. An empty age is the
# fail-open shape -- it reads as "no verdict" to a careless caller -- so the
# caller below treats a non-integer as a FAIL rather than as fresh.
#
# UTC, matching the evidence record at the bottom of this file, so a run at
# 23:00 in one timezone and 01:00 in the next do not disagree about the age of
# the same file by a day. Future dates come back NEGATIVE on purpose: they are
# a stamp no run could have produced, and the caller refuses them instead of
# rounding them to fresh.
load_age_days() { # load_age_days <YYYY-MM-DD> -> whole days since that date, or empty
  python3 - "$1" <<'PYAGE' 2>/dev/null
import datetime, sys
try:
    d = datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(1)
print((datetime.datetime.now(datetime.timezone.utc).date() - d).days)
PYAGE
}

# The three rows of this section are FUNCTIONS, called immediately below, for
# the reason classify_mutation_result, extract_real_tag and spec_field are:
# _shared/probes/load-rows-selftest.sh drives THESE against scratch fixture
# directories, in every verdict each can produce. A selftest that restates the
# branch logic tests the restatement, and a selftest that greps this file for
# the branch cannot tell a branch that works from a branch that is dead.
load_baseline_row() {
  # NA IS "UNASKED", NEVER "ANSWERED". Both NA paths below are about the
  # QUESTION not having been put to this repo -- a ratified decline, or a spec
  # written before dimension 25 existed. Neither is evidence about capacity,
  # and the evidence strings say so, because an N/A that reads like a pass is
  # how a dimension quietly leaves the standard.
  if declined "load_baseline"; then
    row "load-baseline" NA "ratified decline in $SPEC -- capacity is UNMEASURED here by a recorded decision, not by evidence"
    return
  fi
  local has_block=0 has_dir=0 engaged_by
  grep -qE '^load_baseline:' "$SPEC" 2>/dev/null && has_block=1
  [[ -d benchmarks/load ]] && has_dir=1
  if (( has_block == 0 && has_dir == 0 )); then
    row "load-baseline" NA "spec predates dimension 25: no load_baseline block in $SPEC and no benchmarks/load/ -- this repo has never been ASKED for a saturation point, which is not the same as having answered"
    return
  fi
  # Two independent ways in, and the evidence names which one fired, because
  # "you owe a load baseline" is an unhelpful finding if the reader cannot see
  # what created the obligation.
  if (( has_block )); then engaged_by="load_baseline: declared in $SPEC"
  else engaged_by="benchmarks/load/ exists in this repo"; fi

  if [[ ! -f "$LOAD_BASELINE" ]]; then
    row "load-baseline" FAIL "$engaged_by, but $LOAD_BASELINE does not exist -- the artifact this dimension is scored on is missing (prod-bootstrap ships benchmarks/load/baseline-TEMPLATE.md; copy it to $LOAD_BASELINE and fill it from a real run)"
    return
  fi

  # THE TARGET IS CHECKED BEFORE THE DOCUMENT IS PARSED, on purpose. A measured
  # margin with nothing to meet is a number, not a gate, and reporting the
  # document's shortcomings first would send the reader to edit the file that
  # is fine -- the same misattribution implemented_row was fixed for when it
  # blamed a decayed spec for a build failure elsewhere in the repo.
  local target target_norm
  target="$(spec_field load_baseline margin_target)"
  if placeholder_value "$target"; then
    row "load-baseline" FAIL "$LOAD_BASELINE exists but $SPEC declares no load_baseline.margin_target (got '${target:-<absent>}') -- a measured headroom with no committed target is a number nobody can fail"
    return
  fi
  target_norm="$(load_margin_norm "$target")"
  if [[ -z "$target_norm" ]]; then
    row "load-baseline" FAIL "load_baseline.margin_target in $SPEC is '$target' -- it must START with the number, as 3x (factor over expected peak) or 300% (percentage of it), so the probe compares quantities instead of strings"
    return
  fi

  local measured age
  measured="$(load_field 'measured([_ ](at|on))?|measurement[_ ]date|date')"
  if [[ ! "$measured" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    row "load-baseline" FAIL "$LOAD_BASELINE carries no parseable measurement date: wanted a 'measured: YYYY-MM-DD' field, got '${measured:-<no such field>}' -- and the file's mtime is NOT a fallback, because a clone stamps it with the checkout time and would report any baseline as fresh"
    return
  fi
  measured="${BASH_REMATCH[1]}"
  age="$(load_age_days "$measured")"
  if [[ ! "$age" =~ ^-?[0-9]+$ ]]; then
    row "load-baseline" FAIL "could not compute the age of $LOAD_BASELINE from its declared date '$measured' -- a freshness check that produced no age must not report freshness (is python3 on PATH? is the date real, e.g. 2026-02-31?)"
    return
  fi
  if (( age < 0 )); then
    row "load-baseline" FAIL "$LOAD_BASELINE says it was measured on $measured, $(( -age )) day(s) in the FUTURE -- no run produced that stamp, so the date is typed rather than measured and the freshness of everything under it is unknown"
    return
  fi
  if (( age > LOAD_MAX_AGE_DAYS )); then
    row "load-baseline" FAIL "$LOAD_BASELINE was measured on $measured, $age day(s) ago (limit ${LOAD_MAX_AGE_DAYS}) -- a stale capacity measurement describes a system that no longer exists; re-run the load lane or decline the dimension with the reason"
    return
  fi

  local sat
  sat="$(load_field 'saturation[_ -]?point')"
  if placeholder_value "$sat" || [[ ! "$sat" =~ ^[0-9] ]]; then
    row "load-baseline" FAIL "$LOAD_BASELINE declares no saturation point: wanted 'saturation point: <number> <unit>' with the value STARTING at the number, got '${sat:-<no such field>}' -- prose about the saturation point is the keyword-grep form this row exists to refuse"
    return
  fi

  local margin margin_norm mkind mval tkind tval
  margin="$(load_field 'margin|headroom')"
  margin_norm="$(load_margin_norm "$margin")"
  if [[ -z "$margin_norm" ]]; then
    row "load-baseline" FAIL "$LOAD_BASELINE declares no parseable margin: wanted 'margin: <number>x' or 'margin: <number>%', got '${margin:-<no such field>}' -- without it the saturation point is a number with nothing to compare it to"
    return
  fi
  read -r mkind mval <<<"$margin_norm"
  read -r tkind tval <<<"$target_norm"
  if [[ "$mkind" != "$tkind" ]]; then
    row "load-baseline" FAIL "$LOAD_BASELINE reports the margin as a $mkind ('$margin') while $SPEC declares the target as a $tkind ('$target') -- these are different quantities and comparing them would be arithmetic dressed as a verdict; state both the same way"
    return
  fi
  if awk -v a="$mval" -v b="$tval" 'BEGIN{ exit !(a+0 >= b+0) }'; then
    row "load-baseline" PASS "saturation $sat; margin $margin meets the declared target $target; measured $measured ($age day(s) old, limit $LOAD_MAX_AGE_DAYS)"
  else
    row "load-baseline" FAIL "$LOAD_BASELINE reports a margin of $margin against the declared target $target -- the measured headroom does not meet what $SPEC commits to; that is a capacity finding, not a reason to lower the target"
  fi
}
load_baseline_row

# --- 24. error handling as a fitness function (Yuan et al., OSDI 2014) ------
#
# THE FINDING THIS ROW IS BUILT ON, with its numbers, because the numbers are
# the argument. "Simple Testing Can Prevent Most Critical Failures: An Analysis
# of Production Failures in Distributed Data-Intensive Systems" (Yuan, Luo,
# Zhuang, Rodrigues, Zhao, Zhang, Jain, Stumm; OSDI 2014) studied 198 randomly
# sampled user-reported failures across Cassandra, HBase, HDFS, MapReduce and
# Redis:
#
#   * 92% of the CATASTROPHIC failures resulted from incorrect handling of
#     non-fatal errors that the software had ALREADY EXPLICITLY SIGNALLED. The
#     error was detected. The handler is what took the cluster down.
#   * 58% of those catastrophic failures would have been caught by testing the
#     error-handling code alone -- no distributed reasoning, no exotic
#     interleaving, no fault injection into the network.
#   * 35% of them fall into three patterns a reader can spot without running
#     anything: the handler is empty or only logs, the handler body is a
#     TODO/FIXME, or the handler over-catches and aborts the process.
#
# That last group is what makes this a FITNESS FUNCTION rather than a test.
# Those three shapes are properties of the SOURCE, so they belong with the
# import bans and the wall-clock ban of dimension 3: checked by a script the
# probe RUNS, not by a reviewer remembering to look.
#
# WHY THE PROBE DOES NOT IMPLEMENT THE CHECK ITSELF. What counts as an
# over-catch, and which packages are allowed to abort, are repo-specific facts
# -- a composition root SHOULD exit on a failed dependency, and a decision core
# never should. A single expression baked into this vendored file would either
# fire on the correct case (and get widened until it is gone -- the fate this
# framework names explicitly) or be loose enough to certify nothing. So the
# rule lives in the repo, at scripts/error-handling-fitness.sh, and the probe
# does what it does everywhere else: runs the gate, and refuses to describe an
# unrun gate as a clean one.
#
# THE VACUOUS FORMS, named so they are recognisable when someone proposes one:
#
#   - a fitness script that exits 0 having scanned ZERO files. That is the
#     shape this file has shipped three separate times, and it is the script's
#     own obligation to fail loudly on an empty match set -- prod-bootstrap's
#     plan task for this script carries that requirement, and this row cannot
#     see it from outside.
#   - a script present but NOT EXECUTABLE. In CI that is a step that exists in
#     the workflow and never runs.
#   - this row reading the script's PRESENCE instead of its exit status, which
#     would make it a filename check with a paper's name attached.
#
# The first is the script's to refuse; the second and third are what the
# branches below refuse.
EHF="scripts/error-handling-fitness.sh"
error_handling_fitness_row() {
  if [[ ! -e "$EHF" ]]; then
    row "error-handling-fitness" NA "no $EHF -- this repo's scaffold predates the error-handling fitness function (Yuan et al., OSDI 2014: 92% of catastrophic failures come from the handler, not from the error). prod-bootstrap's gap report owes it as a plan task; this NA means UNASKED, never answered"
    return
  fi
  if [[ ! -x "$EHF" ]]; then
    # Deliberately NOT rescued by running it through `bash`. This probe could;
    # CI cannot, because CI invokes it as a program, and a lane that cannot
    # start is indistinguishable from a lane that passed. Certifying it clean
    # from a path CI does not take is the same false green as a required check
    # skipped by a failed `needs:` counting as PASSED.
    row "error-handling-fitness" FAIL "$EHF exists but is not executable ($(ls -l "$EHF" 2>/dev/null | awk '{print $1}')) -- the mode bit is the difference between a gate and a workflow step that reports success without running; chmod +x it"
    return
  fi
  # THE WIRING, merged in 2026-08-27 from the deferred wiring-rows fragment
  # (proposals/2026-08-27-probe-wiring-rows/, now landed and deleted). It was
  # filed as a separate same-named row and could not be landed as one: two rows
  # sharing a dimension name break this file's report and its not-probed
  # derivation, so the check belongs HERE, in the one row that name has.
  #
  # WHY IT IS NEEDED AT ALL, since `cheap-gate` already exists and this row
  # already EXECUTES the script. `cheap-gate` greps for `^check-fast:` in the
  # Makefile: it answers "is there a cheap gate", never "does the cheap gate
  # still run the checks people believe it runs". And this row running the
  # script itself proves the script works -- from a path CI does not take. So
  # deleting the `$(MAKE) error-handling-fitness` line from check-fast's recipe
  # left BOTH of them green while the gate no longer ran in the only place that
  # gates anything. That is the exact shape this probe exists to refuse
  # everywhere else, and it is why the check is the recipe's, not the script's.
  #
  # CHECK-FAST'S OWN RECIPE, extracted first, and NOT a grep over the whole
  # Makefile. Measured while writing this row: the whole-file grep passed after
  # `$(MAKE) error-handling-fitness` was deleted from check-fast, because the
  # standalone `error-handling-fitness:` target's own recipe line still matched.
  # The row certified "wired into the cheap gate" over a gate the cheap gate no
  # longer ran -- which is this file's defining defect, committed by a row added
  # to prevent it.
  #
  # awk from `^check-fast:` to the first line that is neither blank nor
  # tab-indented, which is exactly where a make recipe ends.
  #
  # A THIRD REPAIR, FOUND WHILE LANDING and not in the fragment: the recipe's
  # own COMMENTS are stripped before matching. Without that, commenting the
  # invocation out -- `#\t$(MAKE) error-handling-fitness`, the single most
  # likely way a gate actually gets disabled in a hurry -- left the row PASSing
  # over a recipe make would not run. It is the same defect the fragment
  # already recorded inside the alert fence ("a mention is not a citation"),
  # one file over. Stripping fails CLOSED: a real invocation carrying a
  # trailing comment keeps matching, and anything hidden behind a `#` stops.
  local _cf
  _cf="$(awk '/^check-fast:/{f=1;next} f && /^[^\t]/ && NF{f=0} f' Makefile 2>/dev/null | sed 's/#.*$//')"
  if ! grep -qE '(\$\(MAKE\) error-handling-fitness|scripts/error-handling-fitness\.sh)' <<<"$_cf"; then
    row "error-handling-fitness" FAIL "$EHF exists but check-fast's OWN RECIPE does not invoke it -- a fitness function nothing invokes is a file, not a gate; and note this is read from the recipe, never from the whole Makefile, where the standalone error-handling-fitness: target's own line keeps matching after the cheap gate stops calling it"
    return
  fi
  # Only now the landed behaviour: RUN it, and refuse to describe an unrun gate
  # as a clean one. Wiring first, because a gate that is green in this probe and
  # absent from the cheap gate is the more flattering of the two failures.
  local out rc first
  out="$("$EHF" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    first="$(printf '%s\n' "$out" | grep -m1 -aE '[^[:space:]]' | cut -c1-90)"
    row "error-handling-fitness" PASS "check-fast's recipe invokes it AND $EHF EXECUTED clean this run (exit 0): ${first:-no output}"
  else
    # An evidence-free FAIL is the worst output this probe can produce -- it
    # names no defect, so the only available "fix" is to soften the probe. A
    # script that reds silently still gets a finding with its exit status in it.
    first="$(printf '%s\n' "$out" | grep -m1 -aE '[^[:space:]]' | cut -c1-120)"
    row "error-handling-fitness" FAIL "$EHF is RED (exit $rc): ${first:-no output at all, which is itself a defect in the fitness script -- a gate must name what it rejected}"
  fi
}
error_handling_fitness_row

# --- 25. deterministic simulation (dimension 27) -- ADVISORY, CANNOT FAIL ---
#
# WHAT THE LANE IS. A deterministic simulation runs the whole system inside a
# single simulated world: one seeded PRNG drives every scheduling and fault
# decision, time is a variable the harness advances rather than a clock, and
# the network, the disks and the peers are models the test can partition, stall
# and crash at will. The payoff is that a failing SEED is a reproducible
# distributed bug -- replay it and get the identical interleaving, which is the
# one thing ordinary concurrency testing cannot offer. FoundationDB is the
# reference implementation (Zhou et al., "FoundationDB: A Distributed Unbundled
# Transactional Key Value Store", SIGMOD 2021, §4 -- the simulator was built
# BEFORE the database it tests); TigerBeetle's VOPR runs the same idea
# continuously over seed space.
#
# WHY THIS ROW CANNOT FAIL, AND EXACTLY WHAT WOULD CHANGE THAT.
#
# Nothing in this framework has yet had a defect found by a simulation lane. A
# gate that can turn a build red before it has ever caught anything buys one
# thing: the appearance of coverage. This file's own history is the whole
# argument -- every vacuous row it has had to remove (`grep -qi "reconcil"`,
# the `mutation` keyword search, `grep -rqi "sbom\|syft"`) began as a real
# requirement nobody could satisfy honestly yet, and was therefore satisfied
# dishonestly. A red row that cannot be earned is a red row that gets argued
# down into a keyword.
#
# So this row REPORTS and does not gate, and it is promoted on a checkable
# condition rather than on a date: when stage 1's sim lane has produced its
# first real finding -- a seed that reproduced a defect no other lane caught --
# whoever has that seed converts this into a FAIL-capable row and cites it
# here. Until then PASS means "a lane is present", NA means "there is no lane",
# and NEITHER is a claim that this system was ever simulated.
#
# ONE MECHANICAL NOTE, because it would otherwise break the promise above by
# accident: `row` converts a PASS carrying EMPTY evidence into a FAIL. Both
# evidence strings below therefore begin with a literal, so no combination of
# detections can produce an empty one and hand this row a failing branch it is
# not supposed to have.
simulation_advisory_row() {
  local has_target=0 has_dir=0 missing=""
  # `^sim:` is the TARGET, not the word. A `.PHONY: sim` line names it without
  # defining it, and a Makefile that only declares the phony has no recipe to
  # run -- the same distinction the secret-scan row had to learn between a job
  # DEFINITION and a mention of one.
  grep -qE '^sim:' Makefile 2>/dev/null && has_target=1
  [[ -d verification/simulation ]] && has_dir=1
  if (( has_target && has_dir )); then
    row "simulation-advisory" PASS "sim lane present (advisory): a 'sim:' target in the Makefile and verification/simulation/ ($(find verification/simulation -type f 2>/dev/null | wc -l | tr -d ' ') file(s)) -- PRESENCE ONLY; this row executes no seed and gates nothing"
  else
    (( has_target )) || missing="no 'sim:' target in the Makefile"
    (( has_dir ))    || missing="${missing:+$missing; }no verification/simulation/"
    row "simulation-advisory" NA "no deterministic simulation lane ($missing) -- dimension 27 is ADVISORY: this row cannot FAIL until a sim lane has caught a defect no other lane did, and until then an absent lane is a gap in the roadmap, not in this repo"
  fi
}
simulation_advisory_row

# --- 26. crash-only state identity (Candea & Fox, HotOS IX 2003) ------------
#
# Landed 2026-08-27 from the deferred wiring-rows fragment. Like the wiring
# check merged into section 24, this row probes the EFFECT and not the file:
# scripts/kill-durability.sh existing says nothing about what it asserts.
#
# The scenario itself needs docker and cannot run from this probe, so what is
# probed is the two things that CAN be checked here: that the assertion is
# present in the scenario at all, and -- via the wiring above and the scenario's
# own selftest -- that its logic can still fail. The first is the one that
# decays silently: the scenario runs in exactly one CI job, so a renamed
# /healthz field shows up there and nowhere else.
#
# THE `else` BRANCH IS A REPAIR MADE WHILE LANDING, not part of the fragment.
# The fragment guarded the whole block with `if [[ -f scripts/kill-durability.sh ]]`
# and emitted nothing when the file was absent. Under this file's own
# SILENCE-IS-NOT-A-VERDICT derivation (see below) an unemitted name becomes
# `FAIL not probed`, so a repo that has never been asked for a kill scenario
# would have gone red on a row that never ran. NA means UNASKED here, exactly as
# it does on error-handling-fitness -- never "fine".
KILL_DURABILITY="scripts/kill-durability.sh"
crash_only_state_row() {
  if [[ ! -f "$KILL_DURABILITY" ]]; then
    row "crash-only-state-identity" NA "no $KILL_DURABILITY -- this repo's scaffold predates the crash-only kill scenario (Candea & Fox, HotOS IX 2003). prod-bootstrap's gap report owes it as a plan task; this NA means UNASKED, never answered"
    return
  fi
  if grep -q 'assert_state_identical' "$KILL_DURABILITY" 2>/dev/null; then
    row "crash-only-state-identity" PASS "the kill scenario compares reconstructed state across the crash (assert_state_identical in $KILL_DURABILITY), not only durable records"
  else
    row "crash-only-state-identity" FAIL "$KILL_DURABILITY asserts records survived but never that replaying them reconstructs the same state (no assert_state_identical) -- a boot that read every byte back and rebuilt the state wrong passes it"
  fi
}
crash_only_state_row

# --- 27. differential observability (Huang et al., HotOS 2017) --------------
#
# Landed 2026-08-27 from the deferred wiring-rows fragment.
#
# The alert is the artifact; what makes it REAL is that its client half is a
# series this service does not emit. That is the property to check, and it is
# the one that will be got wrong -- substituting a self-emitted series for the
# client vantage produces an expression that parses, evaluates, and never fires.
#
# NO `WARN` VERDICT, deliberately: row() tallies PASS, FAIL and NA and nothing
# else, so a WARN would render in the table and be counted in none of them --
# invisible under this probe's own `FAIL 0` bar. A verdict the summary cannot
# see is the vacuous form of a row.
#
# The test below is mechanical and fails CLOSED: it requires the alert's
# expression to cite at least one metric identifier that is NOT in
# emitted-metrics.yaml. An extractor that stopped matching finds no external
# series and the row FAILs, rather than passing over an expression it never
# read.
#
# THE `else` BRANCH IS THE SAME REPAIR AS SECTION 26's: the fragment emitted no
# row at all when either file was missing, which this file's derivation turns
# into `FAIL not probed` for every repo without an alert manifest.
differential_observability_row() {
  if [[ ! -f observability/alerts.md || ! -f observability/emitted-metrics.yaml ]]; then
    local _miss=""
    [[ -f observability/alerts.md ]]             || _miss="no observability/alerts.md"
    [[ -f observability/emitted-metrics.yaml ]]  || _miss="${_miss:+$_miss; }no observability/emitted-metrics.yaml"
    row "differential-observability" NA "$_miss -- there is no alert manifest to read a client vantage out of, so this repo has never been ASKED for one (Huang et al., HotOS 2017). UNASKED, never answered"
    return
  fi
  # the alert's own section, from its heading to the next one
  local _gray _declared _external=0 _m
  _gray="$(awk '/^## .*([Gg]ray.?[Ff]ail|DifferentialObservability)/{f=1;print;next} /^## /{f=0} f' observability/alerts.md)"
  _declared="$(grep -oE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*' observability/emitted-metrics.yaml | awk '{print $NF}' | sort -u)"
  if [[ -n "$_gray" ]]; then
    # Identifiers inside the fenced expression only -- prose names series too,
    # and counting those would let a paragraph satisfy the row.
    #
    # AND NOT FUNCTION NAMES. Measured while writing this: without the
    # trailing-paren filter, `min_over_time` and `avg_over_time` counted as
    # "series this service does not emit", so the row PASSED on an expression
    # whose every actual series was self-emitted -- the exact substitution it
    # exists to catch, certified green by two PromQL builtins.
    #
    # AND NOT COMMENTS INSIDE THE FENCE, for the same reason and found the same
    # way: with the `#` lines left in, swapping the live client series for a
    # self-emitted one still PASSED, because the comment ABOVE it still named
    # the external series it no longer used. A mention is not a citation.
    while read -r _m; do
      [[ -n "$_m" ]] || continue
      [[ "$_m" == *"(" ]] && continue          # a call, not a series
      grep -qxF "$_m" <<<"$_declared" || _external=$((_external+1))
    done < <(awk '/^```/{f=!f;next} f' <<<"$_gray" | sed 's/#.*$//' \
             | grep -oE '\b[a-z][a-z0-9]*_[a-z0-9_]+\b\(?' | sort -u)
  fi
  if [[ -n "$_gray" && $_external -gt 0 ]]; then
    row "differential-observability" PASS "gray-failure alert present and citing $_external series this service does not emit (the client vantage)"
  elif [[ -n "$_gray" ]]; then
    row "differential-observability" FAIL "the gray-failure alert cites ONLY series this service emits -- a self-reported client view executes in the same process and goes quiet in exactly the failure the alert exists for"
  elif waived gray-failure-no-external-vantage; then
    row "differential-observability" NA "live waiver with owner+expiry in registries/waivers.yaml"
  else
    row "differential-observability" FAIL "no alert on the DISAGREEMENT between a client vantage and self-reported readiness, and no live waiver (Huang et al., HotOS 2017: the detectable quantity is the gap, not either view)"
  fi
}
differential_observability_row

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
# Matched ANYWHERE on the line, not anchored to its start.
#
# The first version anchored at `^[[:space:]]*(el)?(se)?[[:space:]]*row "` and
# was blind to part of the declared rows, because this file's dominant idiom for
# one-liners puts `row` mid-line after `&&` or `||`.
#
# NUMBERS RE-MEASURED AT THE RECONCILIATION MERGE (2026-08-26), not carried
# over. They had gone stale in the ordinary way: the merge was clean, so nothing
# forced anyone to look at them. As written here they said "9 of the 55"; both
# halves had moved. Measured on the merged tree:
#
#   total declared rows (unanchored)  56   was 55 -- the sigpipe branch added
#                                          probe-self:no-pipe-into-grep-q
#   seen by the anchored form         50
#   blind set                          6   was 9
#
# RE-MEASURED AGAIN AT THE WIRING-ROWS LANDING (2026-08-27), and they had gone
# stale in exactly the way this comment predicts -- the reader who trusted "56"
# would have been three rows out before this change added two more:
#
#   total declared rows (unanchored)  61   was 56 as written above
#   seen by the anchored form         55
#   blind set                          6   the same six, listed below
#
# The blind set is unchanged in MEMBERSHIP, which is the point worth recording:
# both rows landed here (crash-only-state-identity, differential-observability)
# start their line, so they are seen by either form and the argument below is
# untouched by them.
#
#   advisory-lane, auto-recovery:self_recovery, cheap-gate, nightly-trends,
#   registries, secret-scan-all-triggers
#
# The three that LEFT the blind set -- changed-line-coverage,
# ci-runs-integration-lane and sbom -- were rewritten from one-liners into
# multi-line forms by branches merged alongside this one, so they now start
# their line. That is an argument for the unanchored form getting STRONGER, not
# weaker: the blind set is a property of whichever idiom is in use on a given
# day, which is exactly why the derivation must not depend on it.
#
# `registries`/`secret-scan-all-triggers` remain two of the §14/§15 rows the
# sentence below names. A guard blind to its own worked examples is worse than
# no guard: it reads as covering them.
#
# Caught by a reviewer, not by me, and the lesson is the one this file keeps
# relearning -- an anchor that fits the shape you happened to look at.
declared_rows=$(grep -oE 'row "[a-zA-Z][^"$]*"' "$PROBE_SELF" \
  | sed -E 's/row "([^"]*)"/\1/' | sort -u)
# 50, not 20: the real count is 61 (re-measured 2026-08-27 at the wiring-rows
# landing; 56 at the 2026-08-26 reconciliation merge, 55 when this line was
# written), and a floor low enough to be met by a half-broken matcher is a floor
# that would have accepted the 46 above.
#
# THE FLOOR ITSELF IS DELIBERATELY NOT RAISED TO 61. It is not a row census --
# a floor that tracks the count has to be edited on every added row, which is
# the shape of a number that gets edited without being thought about. It fences
# the derivation COLLAPSING, and 50 still does that.
#
# WHAT THIS FLOOR DOES NOT CATCH, said plainly so nobody reads more into it than
# is there: it does NOT catch a regression to the anchored matcher. That form
# derives 55 on this tree (50 before the wiring-rows landing), and neither is
# < 50, so it would pass clean.
# The floor catches a derivation that COLLAPSES -- an empty or near-empty list,
# which is the fail-open shape it was written for -- and nothing finer. Raising
# it to bracket the anchored form would turn it into a number that has to be
# edited every time a row is added, i.e. a number that gets edited without being
# thought about, and it would still only fence one known-bad matcher. The real
# guard against that regression is the comment above plus review, and stating
# the limit here is preferable to a floor that looks stronger than it is.
if (( $(grep -c . <<<"$declared_rows") < 50 )); then
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
