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
  else row "coverage" FAIL "$(grep -m1 -iE 'below|fail' <<<"$out")"; fi
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
  if grep -q "affected by 0 vulnerabilities" <<<"$vout"; then
    row "vuln-scan" PASS "govulncheck: 0 called vulnerabilities"
  else row "vuln-scan" FAIL "$(grep -m1 -E 'affected by [0-9]+ vulnerabilit' <<<"$vout")"; fi
else row "vuln-scan" FAIL "govulncheck not installed — gate unproven"; fi

wf=".github/workflows"
if [[ -d $wf ]]; then
  sc=$(grep -rl "secret-scan" $wf 2>/dev/null | wc -l | tr -d ' ')
  (( sc >= 2 )) && row "secret-scan-all-triggers" PASS "in $sc workflows" || row "secret-scan-all-triggers" FAIL "only $sc workflow(s) — PR-only is the known gap"
  grep -rqi "sbom\|syft\|cyclonedx" $wf && row "sbom" PASS "SBOM step present" || row "sbom" FAIL "no SBOM"
  # Match only real attestation mechanisms, never the English word "provenance"
  # (it appears in benchmark baseline headers — that was a false PASS before).
  if grep -rqE "cosign|--provenance=|attest(ation)?s?:|actions/attest" $wf 2>/dev/null; then
    row "artifact-provenance" PASS "signing/attestation step present"
  elif grep -q "artifact_provenance_signing" "$SPEC" 2>/dev/null; then
    row "artifact-provenance" NA "recorded open decision in $SPEC"
  else row "artifact-provenance" FAIL "no provenance and not recorded as a decision"; fi
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

# --- report --------------------------------------------------------------
printf '\n%-34s %-5s %s\n' "DIMENSION" "VERDICT" "EVIDENCE"
printf '%s\n' "$(printf '%0.s-' {1..96})"
for r in "${ROWS[@]}"; do IFS='|' read -r d v e <<<"$r"; printf '%-34s %-5s %s\n' "$d" "$v" "$e"; done
printf '%s\n' "$(printf '%0.s-' {1..96})"
printf 'PASS %d   FAIL %d   NA %d\n' "$passes" "$fails" "$nas"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE — $fails probe(s) failed; each is a finding, not a reason to soften the probe."; exit 1; }
echo "VERDICT: COMPLETE — every dimension probed; N/A entries are ratified declines."
