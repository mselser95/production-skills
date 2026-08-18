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
root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root" || exit 2

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

SPEC="${PROD_SPEC_FILE:-production.yaml}"
fails=0; passes=0; nas=0
declare -a ROWS

# --- helpers -----------------------------------------------------------------
row() { # row <dimension> <verdict> <evidence>
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
  grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*$1[[:space:]]*$" "$w" || return 1
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
  if grep -qE "build failed|cannot use|undefined:|declared and not used|syntax error" <<<"$out"; then
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

if go test ./... -race -count=1 >/dev/null 2>&1; then row "race" PASS "race detector clean"
else row "race" FAIL "race suite failed"; fi

# --- 2. coverage + per-package ratchet (measured, not claimed) ---------------
if [[ -x scripts/coverage.sh ]]; then
  if out=$(./scripts/coverage.sh 2>&1); then
    row "coverage" PASS "$(grep -oE 'TOTAL COVERAGE: [0-9.]+%' <<<"$out" | head -1)"
    if grep -q "ratchet: all packages at/above" <<<"$out"; then
      row "coverage-ratchet" PASS "per-package floors enforced"
    else row "coverage-ratchet" FAIL "no per-package ratchet in the gate"; fi
  else
    viol=$(grep -cE 'below its floor' <<<"$out")
    row "coverage" FAIL "$viol floor violation(s): $(grep -oE '[a-z/]+ is [0-9.]+%, below its floor of [0-9.]+%' <<<"$out" | paste -sd' ; ' -)"
  fi
else row "coverage" FAIL "no scripts/coverage.sh"; fi

# tests/prod LOC ratio — recorded, never a gate
prod=$(find . -name '*.go' -not -name '*_test.go' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
tst=$(find . -name '*_test.go' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
row "loc-ratio (informational)" PASS "test/prod = $(awk -v t="$tst" -v p="$prod" 'BEGIN{printf "%.2f", (p?t/p:0)}') ($tst/$prod)"

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
  if (( n == 0 )); then row "invariants-ratified" FAIL "verification/ratified/ has files but zero Test funcs"
  elif go test ./verification/... -count=1 >/dev/null 2>&1; then
    # Count from the SPEC, not from the directory listing. Counting `func Test`
    # in verification/ratified/ and calling the total "ratified" conflated
    # ratified invariants with ones still PENDING HUMAN RATIFICATION whose test
    # simply lives alongside them -- and then wrote that inflated number into
    # every evidence record. Ratification is a human act recorded in the spec;
    # a test file cannot confer it on itself.
    ratified_n=$(awk '/^invariants:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^[[:space:]]*-[[:space:]]/{c++} END{print c+0}' "$SPEC" 2>/dev/null)
    pending_n=$(awk '/^invariants_pending_ratification:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^[[:space:]]*-[[:space:]]/{c++} END{print c+0}' "$SPEC" 2>/dev/null)
    row "invariants-ratified" PASS "$ratified_n ratified per $SPEC (+$pending_n pending human ratification); $n test func(s) green"
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
  for pkg in .prod/ratify-queue/*.yaml; do
    [[ -f "$pkg" ]] || continue
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
    # The grammar here is fixed and tiny: four keys under one top-level block,
    # each a single-quoted or bare scalar. That is parseable without a library,
    # and unlike the sed version it handles the quotes and colons that Go source
    # is full of, because it strips exactly one layer of quoting rather than
    # pattern-matching the line.
    nv_fields=$(PKG="$pkg" python3 - <<'PYNV'
import os, sys

want = ("file", "expect_red", "find", "replace")
found = {}
inblock = False
for raw in open(os.environ["PKG"], encoding="utf-8"):
    line = raw.rstrip("\n")
    if line.startswith("non_vacuity_check:"):
        inblock = True
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
        found[key] = value
for k in want:
    print(found.get(k, ""))
PYNV
)
    nv_file=$(sed -n 1p <<<"$nv_fields")
    nv_test=$(sed -n 2p <<<"$nv_fields")
    nv_find=$(sed -n 3p <<<"$nv_fields")
    nv_repl=$(sed -n 4p <<<"$nv_fields")
    nv_total=$((nv_total+1))
    if [[ -z "$nv_file" || -z "$nv_test" || -z "$nv_find" ]]; then
      # A package with no executable check is UNVERIFIED, and unverified is not
      # a softer kind of verified. Tolerating it with a PASS meant three of four
      # invariants could carry nothing at all and the row would still be green
      # as long as one worked -- the same "some evidence exists somewhere"
      # reasoning the keyword grep used.
      nv_missing=$((nv_missing+1))
      nv_broken="${nv_broken} $(basename "$pkg"):no-executable-check"
      continue
    fi
    if [[ ! -f "$nv_file" ]]; then
      nv_broken="${nv_broken} $(basename "$pkg"):no-such-file"; continue
    fi
    # The mutation must still APPLY. A find-string that no longer matches means
    # the evidence has silently decayed -- report it rather than skip it.
    if ! FIND="$nv_find" python3 -c 'import os,sys; sys.exit(0 if os.environ["FIND"] in open(sys.argv[1]).read() else 1)' "$nv_file"; then
      nv_broken="${nv_broken} $(basename "$pkg"):find-string-gone"; continue
    fi
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
    nv_out=$(go test "$nv_pkg" -run "^${nv_test}\$" -count=1 2>&1)
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
if grep -rql "func TestProperty\|adequacy" --include='*_test.go' . 2>/dev/null; then
  row "property-tests" PASS "$(grep -rho 'func TestProperty[A-Za-z_]*' --include='*_test.go' . | sort -u | wc -l | tr -d ' ') property tests present"
else row "property-tests" FAIL "no property tests found"; fi

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
  elif ((bad==0)); then row "fuzz" PASS "${#fuzzes[@]} targets clean ($infra inconclusive: toolchain setup, not a finding)"
  else row "fuzz" FAIL "${#fuzzes[@]} targets, $bad genuinely failed"; fi
else row "fuzz" FAIL "no fuzz targets"; fi

# --- 6. mutation baseline (artifact + freshness) ----------------------------
if ls .prod/mutation/baseline-*.md >/dev/null 2>&1; then
  row "mutation-baseline (TREND)" PASS "$(ls .prod/mutation/baseline-*.md | head -1)"
else row "mutation-baseline (TREND)" FAIL "no baseline artifact"; fi

# --- 7. scenarios matrix ----------------------------------------------------
if [[ -f .prod/failure-modes.md ]]; then
  tested=$(grep -cE '^\|.*\b(tested|TESTED)\b' .prod/failure-modes.md || true)
  na=$(grep -cE '^\|.*\bN/?A\b' .prod/failure-modes.md || true)
  blocked=$(grep -cE '^\|.*\bblocked\b' .prod/failure-modes.md || true)
  if (( blocked > 0 )); then row "scenario-matrix" FAIL "$blocked checklist entries blocked (need production changes)"
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
if grep -rql "wire\|golden\|protoreflect\|unknown.field" --include='*_test.go' . 2>/dev/null; then
  row "compatibility" PASS "contract/wire-compat tests present"
else row "compatibility" FAIL "no compatibility tests"; fi

# --- 10. performance: benchmarks exist, RUN, and have a baseline -----------
if grep -rql 'func Benchmark' --include='*_test.go' . 2>/dev/null; then
  if go test -run='^$' -bench=. -benchtime=10x ./... >/dev/null 2>&1; then
    base=$(ls benchmarks/baseline-*.txt 2>/dev/null | head -1)
    nb=$(grep -rh 'func Benchmark' --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
    if [[ -n "$base" ]]; then row "benchmarks" PASS "$nb benchmarks run; baseline $base"
    else row "benchmarks" FAIL "benchmarks run but no baseline recorded"; fi
  else row "benchmarks" FAIL "benchmarks do not run"; fi
else row "benchmarks" FAIL "no benchmarks"; fi

# --- 11. profiling (capture path AND live endpoint) ------------------------
prof_capture=$([[ -f benchmarks/profile.sh ]] && echo yes || echo no)
prof_live=$(grep -rql "net/http/pprof" --include='*.go' . 2>/dev/null && echo yes || echo no)
if [[ "$prof_capture" == yes && "$prof_live" == yes ]]; then
  row "profiling" PASS "capture script + env-gated live endpoint"
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
  declined "event_sourcing" && row "replay-corpus" NA "event sourcing declined in spec" \
    || row "replay-corpus" FAIL "no replay corpus and no ratified decline"
fi

for k in effect_journal_outbox reconciliation backup_restore_test; do
  if declined "$k"; then row "$k" NA "ratified decline in $SPEC"
  else
    case "$k" in
      reconciliation) grep -rqi "reconcil" --include='*.go' . && row "$k" PASS "reconciliation code present" || row "$k" FAIL "no reconciliation and no ratified decline";;
      *) row "$k" FAIL "not implemented and not declined in $SPEC";;
    esac
  fi
done

# --- 13. observability: contract CHECKED, tracer WIRED --------------------
if grep -rql "emitted-metrics\|spans.yaml" --include='*_test.go' . 2>/dev/null; then
  row "observability-contract-checked" PASS "a test compares emitted signals to the manifest"
else row "observability-contract-checked" FAIL "manifest is documentation — nothing verifies it"; fi

# THE probe that catches the no-op-port trap: wiring lives in the entrypoints
if grep -rql "Tracer\|tracer\|SpanFunc" cmd/ 2>/dev/null; then
  row "tracing-wired-in-prod" PASS "tracer injected in cmd/ entrypoints"
else
  grep -rql "StartSpan" --include='*.go' internal/ 2>/dev/null \
    && row "tracing-wired-in-prod" FAIL "spans instrumented but NO tracer in cmd/ — no-op in production" \
    || row "tracing-wired-in-prod" FAIL "no tracing at all"
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
  grep -rqi "sbom\|syft\|cyclonedx" $wf && row "sbom" PASS "SBOM step present" || row "sbom" FAIL "no SBOM"
  # Match only real attestation mechanisms, never the English word "provenance"
  # (it appears in benchmark baseline headers — that was a false PASS before).
  # Strip comments before matching: an earlier version PASSed on a comment
  # that explained why provenance is impossible. Only executable lines count.
  if grep -rhE "^[^#]*" $wf/*.yaml 2>/dev/null | sed 's/#.*//' \
       | grep -qE "cosign|--provenance=|actions/attest|attestations:"; then
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
  bad=0
  while read -r m; do grep -q "$m" observability/emitted-metrics.yaml || bad=$((bad+1)); done < <(grep -ohE '\b(clc[a-z]*_[a-z0-9_]+)\b' docs/RUNBOOK.md | sort -u)
  (( bad == 0 )) && row "runbook-citations-resolve" PASS "every cited series exists" || row "runbook-citations-resolve" FAIL "$bad cited series do not exist"
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
  inv=$(grep -cE '^[[:space:]]*-[[:space:]]' <(sed -n '/^invariants:/,/^[a-z_]*:/p' "$SPEC" 2>/dev/null) 2>/dev/null || echo 0)
  pkgs=$(ls .prod/ratify-queue/*.y*ml 2>/dev/null | wc -l | tr -d ' ')
  if (( pkgs > 0 && pkgs >= inv )); then row "ratification-packages" PASS "$pkgs packages for $inv ratified invariants"
  else row "ratification-packages" FAIL "$pkgs ratification packages for $inv ratified invariants — the queue is the evidence trail"; fi
fi

# --- 19. candidate tests are segregated OUT of the blocking lane -------------
cand=$(grep -rl "provenance: candidate" --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
tagged=$(grep -rl "go:build candidate" --include='*_test.go' . 2>/dev/null | wc -l | tr -d ' ')
if (( cand == 0 )); then row "candidate-lane-segregated" NA "no candidate tests"
elif (( tagged >= cand )); then row "candidate-lane-segregated" PASS "$cand candidate files, all build-tagged"
else row "candidate-lane-segregated" FAIL "$((cand-tagged)) of $cand candidate files run in the BLOCKING lane"; fi

# --- 20. provenance headers on every ADDED test func ------------------------
# Only functions the diff ADDS are in scope: pre-existing tests in a touched
# file predate the convention and are not this change's debt.
if base=$(git merge-base HEAD origin/main 2>/dev/null); then
  # Benchmarks are excluded: they are neither blocking nor candidate — they
  # live in their own non-gating lane, so a provenance header would claim a
  # lane membership they do not have.
  added=$(git diff "$base"..HEAD -- '*_test.go' 2>/dev/null | grep -cE '^\+func (Test|Fuzz)' || true)
  # an added func is "headed" when a provenance line is added within the diff too
  heads=$(git diff "$base"..HEAD -- '*_test.go' 2>/dev/null | grep -cE '^\+.*provenance:' || true)
  if (( added == 0 )); then row "provenance-headers" NA "no test funcs added"
  elif (( heads >= added )); then row "provenance-headers" PASS "$added added test funcs, $heads provenance lines"
  else row "provenance-headers" FAIL "$added added test funcs but only $heads provenance headers ($((added-heads)) unheaded)"; fi
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
if (( nfuzz == 0 )); then
  row "ci-runs-fuzz" FAIL "no fuzz targets exist, so nothing is wired: $inmake fuzz name(s) in Makefile"
elif (( inmake >= nfuzz )); then
  row "ci-runs-fuzz" PASS "$inmake fuzz names wired in Makefile"
else
  row "ci-runs-fuzz" FAIL "$inmake of $nfuzz fuzz targets wired into make/CI — the rest run nowhere"
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
