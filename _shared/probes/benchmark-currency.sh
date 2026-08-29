#!/usr/bin/env bash
# benchmark-currency.sh — is each committed benchmark score still ABOUT the
# skill it sits next to?
#
# WHY THIS EXISTS
#
# install.sh already carries the sentence this file is another instance of:
# "Integrity is not currency." A hash proves the installed copy was not
# tampered with and says nothing about whether it is the CURRENT one. A
# benchmark score is the same: `report.json` is a real measurement, honestly
# produced, and it stops describing the skill the moment SKILL.md changes.
#
# Measured 2026-08-29:
#
#   skill              benchmarked   SKILL.md last edited
#   -----------------  ------------  --------------------
#   prod-ops           2026-08-17    2026-08-29     (12 days)
#   prod-curate        2026-08-17    2026-08-29
#   prod-review        2026-08-17    2026-08-29
#   prod-spec          2026-08-17    2026-08-28
#   prod-incident      2026-08-17    2026-08-28
#   prod-test-synth    2026-08-17    2026-08-27
#   prod-implement     2026-08-17    2026-08-27
#
# EVERY score in the repo predates the skill it scores. prod-ops reads
# "FAIL, 12.5% < floor 60.0%" -- a number about a document that no longer
# exists, sitting in the directory of the document that replaced it. Somebody
# reading it would reasonably start rewriting prod-ops to fix a score that was
# never measured against what they are editing.
#
# ADVISORY BY CONSTRUCTION, and that is a decision, not laziness. Refreshing
# these requires `skill-optimizer run`, which needs Codex/OpenAI credentials
# this machine does not have. A gate that fails until a human performs an
# action they may not be able to perform is a gate that gets disabled, and it
# would take the honest gates with it. So this reports and exits 0 -- the
# framework's own GATE/SIGNAL discipline, applied to the file that discipline is
# written in.
#
# Exit: always 0. Read the output.
set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root" || exit 0
skills=(prod-spec prod-review prod-incident prod-implement prod-test-synth
        prod-ops prod-curate prod-bootstrap prod-new)

stale=0 fresh=0 absent=0

for s in "${skills[@]}"; do
  report="$s/benchmark-results/report.json"
  md="$s/SKILL.md"
  [[ -f "$md" ]] || continue

  if [[ ! -f "$report" ]]; then
    printf '  %-18s NO SCORE      never benchmarked -- absence of a score is not a good one\n' "$s"
    absent=$((absent + 1))
    continue
  fi

  # The report's own timestamp, not the file's mtime: a checkout or a copy
  # restamps mtime and would make every stale score look minted this morning.
  # Same reason verify-standard.sh refuses mtime for the load baseline.
  bench=$(python3 -c '
import json,sys
try:
    print((json.load(open(sys.argv[1])).get("timestamp") or "")[:10])
except Exception:
    print("")' "$report" 2>/dev/null)

  # git commit date of SKILL.md, not mtime, for the same reason.
  edited=$(git log -1 --format=%cs -- "$md" 2>/dev/null)

  if [[ -z "$bench" || -z "$edited" ]]; then
    printf '  %-18s UNKNOWN       cannot compare (bench=%s edited=%s) -- an uncomparable pair is not a fresh one\n' \
      "$s" "${bench:-?}" "${edited:-?}"
    stale=$((stale + 1))
    continue
  fi

  if [[ "$bench" < "$edited" ]]; then
    printf '  %-18s STALE         scored %s, SKILL.md edited %s -- the score describes an earlier document\n' \
      "$s" "$bench" "$edited"
    stale=$((stale + 1))
  else
    printf '  %-18s current       scored %s, SKILL.md edited %s\n' "$s" "$bench" "$edited"
    fresh=$((fresh + 1))
  fi
done

echo
if (( stale == 0 && absent == 0 )); then
  echo "benchmark-currency: all ${fresh} score(s) postdate the skill they measure."
else
  echo "benchmark-currency: ${stale} stale, ${absent} never benchmarked, ${fresh} current."
  echo "  A stale score is not a finding about the skill -- it is a finding about the score."
  echo "  Do NOT act on the gaps in a stale report: they were measured against text that has"
  echo "  since changed. Refresh with 'skill-optimizer run' (needs Codex auth), then read them."
fi
exit 0
