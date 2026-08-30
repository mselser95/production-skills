#!/usr/bin/env bash
# sbom-ordering-selftest.sh -- the committed mutation matrix for the `sbom` row
# of verify-standard.sh.
#
# WHY THIS FILE EXISTS. The row it covers replaced
# `grep -rqi "sbom\|syft\|cyclonedx" $wf`, which asked whether the WORD appears
# and PASSed for weeks in a repo where the sbom job had never once succeeded.
# Its replacement is ~110 lines of graph-walking, and the matrix that proved it
# was run BY HAND and recorded in a commit message -- so nothing re-ran it, the
# next edit had no signal, and the matrix was not reviewable as code. Reported
# by agatticelli on binance-marketdata#26, and the hand-run matrix did already
# have a gap: it covered neither "delete the sbom job from ci.yaml alone" nor an
# `artifact-name` mismatch, and BOTH passed.
#
# HOW IT TESTS. It lifts the probe's own program out of verify-standard.sh by
# its heredoc MARKER and feeds it fixtures, rather than restating the logic --
# a selftest that reimplements the parser tests the reimplementation, not the
# thing that runs. Matching the marker and not the whole opening line is
# deliberate: non-vacuity-selftest.sh:273-276 records six cases that silently
# went empty when a `2>/dev/null` was appended to the line they anchored on.
#
# The fixtures are the JSON the yq stage emits (`<file>\t<json>`), so these
# cases need no yq and no workflow trees, and they run anywhere python3 does.
set -uo pipefail

# CASES counts what actually RAN. Until 2026-08-30 this suite ended with a bare
# "ok", which prints identically over sixty-five cases and over zero -- the
# checked-and-none vs nothing-checked confusion this repo refuses everywhere
# else, sitting in its own verifier. Found while deriving a mutation baseline
# from these counts: three suites had none to give.
CASES=0
# Guarded: an unguarded cd here would leave the selftest running in whatever
# directory the caller happened to be in, and every case below resolves its
# subject relative to the repo root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || { echo "sbom-ordering selftest: cannot reach the repo root" >&2; exit 2; }

# RESOLVE THE TARGET IN EITHER LAYOUT (added 2026-08-29).
#
# This line used to be `PROBE="scripts/verify-standard.sh"` and nothing else. That path exists only in an
# INSTANTIATED repo; in this framework repo the canonical file lives at
# `_shared/probes/verify-standard.sh`. So the selftest refused to run (exit 1, fail-closed and correct
# as far as it went) in the one repository where the file it tests is actually
# EDITED. verify-standard.sh is changed here and executed there, which meant
# every edit to the canonical probe went unverified by its own selftest unless
# somebody happened to instantiate a template and run `make probe-selftests`.
#
# That is not hypothetical: on 2026-08-29 two probe changes had left this
# selftest RED for weeks, and it was found only by running the target out of
# curiosity about an unrelated reference.
#
# Template path first so an instantiated repo keeps testing ITS OWN vendored
# copy (the one that will actually run there), canonical second. Still fails
# closed when neither exists -- a gate that cannot run must not look like one
# that passed.
PROBE="scripts/verify-standard.sh"
[[ -r "$PROBE" ]] || PROBE="_shared/probes/verify-standard.sh"
[[ -r "$PROBE" ]] || { echo "sbom-ordering selftest: cannot read $PROBE" >&2; exit 1; }

prog="$(sed -n "/<<'PYSBOM'/,/^PYSBOM\$/p" "$PROBE" | sed '1d;$d')"
# A GATE THAT COULD NOT RUN MUST NOT LOOK LIKE A GATE THAT PASSED. If the
# marker ever stops matching, every case below would run an EMPTY program,
# python3 would print nothing, and each `check` would compare "" against "" --
# all green, nothing tested. Refuse instead.
if [[ "$(wc -l <<<"$prog")" -lt 40 ]]; then
  echo "sbom-ordering selftest: extracted program is $(wc -l <<<"$prog") lines -- the PYSBOM marker no longer matches" >&2
  exit 1
fi

fails=0
echo "sbom-ordering selftest: start"

# THE FIXTURES CARRY THEIR OWN CONFIG. Every case below models a reusable-
# workflow pipeline (clcsolutions/ci/.github/workflows/sbom.yaml@main and
# friends). Since 346b659 the probe learns which reusable workflow produces an
# SBOM from PROD_SBOM_CONSUMES instead of a hardcoded org map -- and that commit
# did not update this file. wf_of() then matched nothing, any_consumer stayed
# False, and ALL EIGHT cases failed with the same "no job PRODUCES an SBOM".
#
# It stayed invisible because nothing in the framework repo invokes this
# selftest (`make probe-selftests` is referenced by nothing at all) and the one
# place it does run is a scaffolded repo's CI. Measured 2026-08-29 in a freshly
# instantiated template: `make probe-selftests` -> 8 cases failed.
#
# A selftest that depends on ambient environment is not hermetic. These are
# applied per-invocation rather than exported globally, so the NA case at the
# end can deliberately drop them and exercise the uninjected path.
# sbom-scan.yaml is deliberately ABSENT from this map. The transitivity case
# below routes the ordering edge through it precisely because it is NOT itself a
# consumer -- it reads the SBOM document, not the image artifact. Listing it here
# made it a second consumer, and the case then "passed" for the wrong reason
# (proving a direct edge, not a transitive one), which is why its expected text
# stopped matching.
SBOM_CONSUMES_FIXTURE="sbom.yaml:svc"
SBOM_DELETES_FIXTURE="image-push.yaml:svc"

# run_case <name> <expected-substring> <stdin-lines>
run_case() {
  CASES=$((CASES+1))
  local name="$1" want="$2" input="$3" got
  got="$(printf '%s\n' "$input" \
    | PROD_SBOM_CONSUMES="$SBOM_CONSUMES_FIXTURE" \
      PROD_SBOM_DELETES="$SBOM_DELETES_FIXTURE" python3 -c "$prog" 2>&1)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name — wanted a verdict containing '${want}', got: ${got}" >&2
    fails=$((fails+1))
  fi
}

j() { printf '%s' "$1"; }

ORDERED='[{"job":"docker-build","uses":"clcsolutions/ci/.github/workflows/go-docker-build.yaml@main","needs":[],"art":"svc"},{"job":"sbom","uses":"clcsolutions/ci/.github/workflows/sbom.yaml@main","needs":["docker-build"],"art":"svc"},{"job":"push","uses":"clcsolutions/ci/.github/workflows/image-push.yaml@main","needs":["docker-build","sbom"],"art":"svc"}]'

run_case "control: sbom ordered before the deleter" "PASS|SBOM ordered before the artifact deleter (sbom before push)" \
  "ci.yaml	${ORDERED}"

# THE ONE THAT SHIPPED GREEN. push deletes the image and ships it while no job
# in that workflow reads it; a second file still has an sbom job, so the row
# believed it had a consumer and printed `PASS  ... deleter ()` -- a green
# attestation over an empty set.
run_case "a deleter with NO consumer in its own workflow" "NO job in this workflow reads it" \
  "ci.yaml	[{\"job\":\"push\",\"uses\":\"clcsolutions/ci/.github/workflows/image-push.yaml@main\",\"needs\":[\"docker-build\"],\"art\":\"svc\"}]
pr.yaml	[{\"job\":\"sbom\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom.yaml@main\",\"needs\":[],\"art\":\"svc\"}]"

run_case "the ordering edge removed" "is not in its needs" \
  "ci.yaml	[{\"job\":\"sbom\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom.yaml@main\",\"needs\":[],\"art\":\"svc\"},{\"job\":\"push\",\"uses\":\"clcsolutions/ci/.github/workflows/image-push.yaml@main\",\"needs\":[\"docker-build\"],\"art\":\"svc\"}]"

# THE SECOND GAP IN THE HAND-RUN MATRIX. Same suffix, different artifact-name:
# the sbom job inventories a DIFFERENT image from the one push ships, so the
# deployed image is uninventoried and the row must not read them as a pair.
run_case "artifact-name mismatch is not the same artifact" "NO job in this workflow reads it" \
  "ci.yaml	[{\"job\":\"sbom\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom.yaml@main\",\"needs\":[],\"art\":\"otra\"},{\"job\":\"push\",\"uses\":\"clcsolutions/ci/.github/workflows/image-push.yaml@main\",\"needs\":[\"sbom\"],\"art\":\"svc\"}]"

# Expected text realigned 2026-08-29: 346b659 reworded this verdict from "no job
# uses sbom.yaml -- ... the job is not there" to the producer-centred message
# below, and did not update the case. The BEHAVIOUR never changed; the assertion
# was pinned to a sentence that no longer existed, so it failed for a reason
# that had nothing to do with what it guards.
run_case "no sbom job at all" "no job PRODUCES an SBOM" \
  "ci.yaml	[{\"job\":\"push\",\"uses\":\"clcsolutions/ci/.github/workflows/image-push.yaml@main\",\"needs\":[],\"art\":\"svc\"}]"

# A CONSUMER WITH NO DELETER IS NOT A DEFECT. Artifacts are per-run, so a PR
# lane that builds and inventories but never pushes has nothing to order
# against -- this pins the row against over-reporting.
run_case "a consumer with no deleter in that file" "no artifact-deleting job in the graph" \
  "pr.yaml	[{\"job\":\"sbom\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom.yaml@main\",\"needs\":[],\"art\":\"svc\"}]"

# TRANSITIVITY: the edge may run through another job. sbom-scan reads the SBOM
# document, not the image, so it is not itself a consumer -- but it still
# carries the ordering.
run_case "a transitive edge counts" "PASS|SBOM ordered before the artifact deleter (sbom before push)" \
  "ci.yaml	[{\"job\":\"sbom\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom.yaml@main\",\"needs\":[],\"art\":\"svc\"},{\"job\":\"sbom-scan\",\"uses\":\"clcsolutions/ci/.github/workflows/sbom-scan.yaml@main\",\"needs\":[\"sbom\"],\"art\":\"svc\"},{\"job\":\"push\",\"uses\":\"clcsolutions/ci/.github/workflows/image-push.yaml@main\",\"needs\":[\"sbom-scan\"],\"art\":\"svc\"}]"

# AN UNREADABLE FILE IS A FINDING, NOT A SKIP. The yq stage prints PARSE_ERROR
# rather than nothing, so an unparseable workflow cannot silently reduce the
# graph to one the row happens to approve of.
run_case "an unparseable workflow fails, never skips" "is unparseable" \
  "ci.yaml	PARSE_ERROR
pr.yaml	${ORDERED}"

# --- the uninjected-map branch, and the line that keeps it honest -------------
#
# These two deliberately run WITHOUT PROD_SBOM_CONSUMES, so they cannot use
# run_case. They pin the distinction the NA branch turns on, and the second is
# the one that stops NA becoming a blanket excuse: an uninjected map may only
# produce NA when the pipeline is actually built from reusable workflows the
# probe was never taught to classify. A repo of plain inline jobs with no SBOM
# at all is perfectly knowable, and must still FAIL.
run_case_nomap() {
  CASES=$((CASES+1))
  local name="$1" want="$2" input="$3" got
  got="$(printf '%s\n' "$input" | env -u PROD_SBOM_CONSUMES -u PROD_SBOM_DELETES python3 -c "$prog" 2>&1)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name — wanted a verdict containing '${want}', got: ${got}" >&2
    fails=$((fails+1))
  fi
}

run_case_nomap "reusable workflows + no map injected is UNKNOWABLE, not absent" "NA|the SBOM ordering invariant is UNKNOWABLE here" \
  "ci.yaml	${ORDERED}"

# No `uses:` naming a .yaml/.yml anywhere: nothing was delegated, so the absence
# of an SBOM is a measured fact rather than a gap in what we were told.
run_case_nomap "plain inline jobs with no SBOM still FAIL without a map" "no job PRODUCES an SBOM" \
  "ci.yaml	[{\"job\":\"build\",\"uses\":\"\",\"needs\":[],\"art\":\"svc\",\"steps\":\"[{run: go build ./...}]\"},{\"job\":\"push\",\"uses\":\"\",\"needs\":[\"build\"],\"art\":\"svc\",\"steps\":\"[{run: docker push}]\"}]"

if (( fails != 0 )); then
  echo "sbom-ordering selftest: ${fails} case(s) failed" >&2
  exit 1
fi
echo "sbom-ordering selftest: ok -- $CASES case(s)"
exit 0
