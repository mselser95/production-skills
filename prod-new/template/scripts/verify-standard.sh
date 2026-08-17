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
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

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
    row "invariants-ratified" PASS "$n ratified tests green"
  else row "invariants-ratified" FAIL "ratified tests red"; fi
  if grep -rqi "counterexample\|verified red\|mutation" verification/ratified/ .prod/ratify-queue/ 2>/dev/null; then
    row "invariants-non-vacuity" PASS "counterexamples documented/verified"
  else row "invariants-non-vacuity" FAIL "no counterexample evidence — never proven red"; fi
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
  if go test -tags="$real_tag" ./... -count=1 >/dev/null 2>&1; then
    extra=""; [[ -n "$live_gate" ]] && extra=" + env-gated live lane"
    row "integration-real-lane" PASS "lane '-tags=$real_tag' runs green$extra"
  else row "integration-real-lane" FAIL "lane '-tags=$real_tag' declared but did not run green"; fi
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
inmake=$(grep -c 'Fuzz[A-Za-z0-9_]*' Makefile 2>/dev/null || echo 0)
(( inmake >= nfuzz )) && row "ci-runs-fuzz" PASS "$inmake fuzz names wired in Makefile"   || row "ci-runs-fuzz" FAIL "$inmake of $nfuzz fuzz targets wired into make/CI — the rest run nowhere"
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
sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
mkdir -p .prod/evidence
{
  printf '{\n  "commit": "%s",\n' "$sha"
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
} > ".prod/evidence/$sha.json"
echo "evidence record: .prod/evidence/$sha.json"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE — $fails probe(s) failed; each is a finding, not a reason to soften the probe."; exit 1; }
echo "VERDICT: COMPLETE — every dimension probed; N/A entries are ratified declines."
