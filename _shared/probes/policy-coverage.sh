#!/usr/bin/env bash
# policy-coverage.sh — which tier-policy keys does the probe actually SCORE?
#
# WHY THIS EXISTS. This framework's defining defect is a requirement declared in
# policy and executed by nothing: it reads as covered, it survives review, and
# it is discovered years later by the incident it was written to prevent. The
# probe hunts that shape everywhere EXCEPT in its own relationship to the policy
# file, and measured 2026-08-28 the answer was ten keys — including
# `chaos_engineering`, `consistency_verification`, `delivery` (the canary
# analysis) and `overload`, four properties this collection now has RUNNABLE
# DEMOS for, so the mechanism is proven and only the row is missing.
#
# WHAT IT IS NOT. It does not check that a row is any good — `artifact-provenance`
# exists, is listed here as covered, and gives the SAME verdict to a sign-only
# workflow and a with-provenance one (slsa-provenance-demo measured it). Row
# QUALITY is the non-vacuity selftests' job. This answers the cheaper prior
# question: is there a row at all.
#
# THE MAPPING IS THE HONEST PART. A raw grep for the key name reports 29 missing
# and is wrong: `liability_registries` is scored by the `registries` rows,
# `supply_chain` by four separate rows, `formal_methods` by `simulation-advisory`.
# Those aliases are declared below, by hand, each one a claim a reader can check.
# An alias added to silence a finding rather than to record a real row is the way
# this file goes bad, so every entry names the row(s) and nothing else.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../.." || exit 2

POLICY="_shared/tier-policy.yaml"
PROBE="_shared/probes/verify-standard.sh"
[[ -f "$POLICY" && -f "$PROBE" ]] || { echo "policy-coverage: need $POLICY and $PROBE" >&2; exit 2; }

# key:row[,row...] — the property is scored under a DIFFERENT name than the key.
ALIASES="
liability_registries:registries,registries-expiry-gated
deployment_resource_limits:deployment-resource-limits
dependency_currency:dependency-lockfile
backup_restore_test:backup-restore-test
domain_boundaries:domain-boundaries:role_matches_topology
slo:slo-objectives-ratified,ops:SLO.md
write_surface_authn:write-surface-authn
consistency_verification:consistency-verification
overload:overload:ingress_shedding,overload:retry_budget
authz_invariants:authz-invariants
sast_specialized:sast-blocking
mutation:mutation-baseline (TREND)
runbooks:runbook-citations-resolve
supply_chain:sbom,vuln-scan,secret-scan-all-triggers,artifact-provenance
scenario_coverage:scenario-matrix
global_coverage_policy:coverage,coverage-ratchet
changed_line_coverage_signal:changed-line-coverage
integration_fidelity:integration-real-lane,ci-runs-integration-lane,contract-artifacts
invariant_counters:invariants-ratified,invariants-non-vacuity
continuous_profiling:profiling
evidence_record:operational-determinism
crash_only_recovery:crash-only-state-identity
load_testing:load-baseline
schema_evolution:compatibility
consumer_contracts:contract-artifacts
formal_methods:simulation-advisory
metamorphic:property-tests
fault_injection:scenario-matrix
tests_per_prod_loc:tests
distributed_tracing:tracing-wired-in-prod,observability:trace_propagation
capacity:load-baseline,benchmarks
reconciliation:auto-recovery:self_recovery
isolation_and_backpressure:scalability:partition_key
"

# Keys with NO row, recorded as known debt with the demo that already proves the
# property where one exists. Being on this list is not absolution: it is the
# work list, and a key here with a demo beside it is a row somebody can write
# this afternoon.
KNOWN_UNSCORED="
chaos_engineering               chaos-steady-state-demo
delivery                        canary-abort-demo
"

# SPACES AND PARENS ARE PART OF SOME ROW NAMES. The pattern was
# `row "[a-z0-9:_-]+"`, which cannot match `mutation-baseline (TREND)` or
# `loc-ratio (informational)`, so neither ever entered this inventory. A key
# aliased to one of them therefore looked unscored -- and that is exactly how
# `mutation` came to be recorded on the work list as "DELIBERATE: a PASS/FAIL
# row would contradict the key", when the row exists, emits PASS/FAIL, and was
# mutation-tested on 2026-08-29 (move .prod/mutation aside -> FAIL "no baseline
# artifact").
#
# There is no contradiction with `mode: advisory` either: the row gates that the
# baseline ARTIFACT exists and is refreshed, not the mutation SCORE. That is
# what "a baseline artifact, refreshed; trend, not a gate" asks for.
#
# An incomplete inventory turns an existing row into an absence, and the absence
# then gets explained rather than checked. Same denominator defect that inflated
# a coverage claim earlier the same day.
rows="$(grep -oE 'row "[a-zA-Z0-9:_ ()-]+"' "$PROBE" | sed 's/row "//;s/"$//' | sort -u)"
[[ -n "$rows" ]] || { echo "policy-coverage: extracted ZERO rows from $PROBE -- a comparison against nothing is not a comparison." >&2; exit 2; }

keys="$(awk '/^defaults: &defaults/{f=1;next} /^tiers:/{f=0} f && /^  [a-z_]+:/{gsub(/:.*/,"");gsub(/ /,"");print}' "$POLICY" | sort -u)"
[[ -n "$keys" ]] || { echo "policy-coverage: extracted ZERO keys from $POLICY." >&2; exit 2; }

nkeys=0; nscored=0; nknown=0; nnew=0
declare -a NEW=()
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  nkeys=$((nkeys+1))
  hyphen="${k//_/-}"
  if grep -qF -- "$k" <<<"$rows" || grep -qF -- "$hyphen" <<<"$rows"; then nscored=$((nscored+1)); continue; fi
  # Bash parameter expansion, not awk -F:. The first version used awk with a
  # colon field separator and `$1=""`, which rebuilds the record with SPACE
  # separators (leaving a leading blank that broke every comparison) and also
  # split `scalability:partition_key` at its own colon. Every alias read as
  # broken, and the run reported 25 findings that were all this bug. Found by
  # executing it, which is the only way a parser bug of this shape is ever found.
  alias_rows=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "${entry%%:*}" == "$k" ]] && { alias_rows="${entry#*:}"; break; }
  done <<<"$ALIASES"
  if [[ -n "$alias_rows" ]]; then
    ok=1
    while IFS= read -r r; do [[ -z "$r" ]] && continue; grep -qxF -- "$r" <<<"$rows" || ok=0; done < <(tr ',' '\n' <<<"$alias_rows")
    if (( ok )); then nscored=$((nscored+1)); continue; fi
    echo "  ALIAS BROKEN  $k -> $alias_rows (a row named there no longer exists)" >&2
    NEW+=("$k"); nnew=$((nnew+1)); continue
  fi
  if awk -v key="$k" '$1==key{found=1} END{exit !found}' <<<"$KNOWN_UNSCORED"; then
    nknown=$((nknown+1)); continue
  fi
  NEW+=("$k"); nnew=$((nnew+1))
done <<<"$keys"

printf 'policy-coverage: %d keys -- %d scored, %d known-unscored (the work list), %d NEW\n' \
  "$nkeys" "$nscored" "$nknown" "$nnew"

if (( nnew )); then
  printf '\nNEW UNSCORED KEYS -- declared in policy, scored by nothing, and not on the work list:\n' >&2
  for k in "${NEW[@]}"; do printf '  %s\n' "$k" >&2; done
  printf '\nEither write the row, or add the key to KNOWN_UNSCORED with the demo that proves\nits property. A policy key nothing scores is this framework name for a lie.\n' >&2
  exit 1
fi
exit 0
