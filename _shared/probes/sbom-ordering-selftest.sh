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
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROBE="scripts/verify-standard.sh"
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

# run_case <name> <expected-substring> <stdin-lines>
run_case() {
  local name="$1" want="$2" input="$3" got
  got="$(printf '%s\n' "$input" | python3 -c "$prog" 2>&1)"
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

run_case "no sbom job at all" "the job is not there" \
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

if (( fails != 0 )); then
  echo "sbom-ordering selftest: ${fails} case(s) failed" >&2
  exit 1
fi
echo "sbom-ordering selftest: ok"
exit 0
