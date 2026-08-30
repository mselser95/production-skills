#!/usr/bin/env bash
# gap-report-consistency.sh — the gap report's summary must agree with its tables.
#
# WHY, and it is not hypothetical.
#
# .prod/gap-report.md carries dimension rows, a second "rows humans forget"
# table, and a hand-written severity summary. On 2026-08-30 the summary said
# "high (0)" and "low (0)" while the tables still held two `high` and four `low`
# rows: successive passes had updated the dimension table and left the second one
# describing the repo as it had been hours earlier. One of the stale rows was
# hiding a genuinely open item.
#
# That is the same rot this repo gates against everywhere else -- a count someone
# typed, drifting away from the set it claims to summarise -- sitting in the
# document the whole bootstrap produces. A gap report that misstates its own
# gaps is worse than none: it is read as the answer.
#
# So the counts are DERIVED from the tables and compared to what the summary
# claims. The summary stays prose (it explains WHY each row is where it is, which
# no generator can), but its numbers have to be true.
#
# Exit: 0 they agree · 1 they do not · 2 refused to answer
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

REPORT=".prod/gap-report.md"
[[ -r "$REPORT" ]] || { echo "gap-report-consistency: no $REPORT" >&2; exit 2; }

# Severity is the LAST cell of every table row. Header and separator rows are
# dropped by their own contents rather than by position, so a table gaining a
# column does not silently shift what gets counted.
counts=$(awk -F'|' '
  /^\|/ {
    n = NF
    sev = $(n-1)
    gsub(/^[ \t]+|[ \t]+$/, "", sev)
    if (sev == "sev" || sev ~ /^-+$/ || sev == "") next
    if (sev == "\xe2\x80\x94" || sev == "-") { closed++; next }
    open[sev]++
  }
  END {
    printf "closed=%d", closed
    for (k in open) printf " %s=%d", k, open[k]
    printf "\n"
  }' "$REPORT")

[[ -n "$counts" ]] || { echo "gap-report-consistency: parsed ZERO rows from $REPORT -- a comparison against nothing is not a comparison" >&2; exit 2; }

total=$(awk -F'closed=' '{print $2}' <<<"$counts" | awk '{print $1}')
[[ -n "$total" && "$total" -gt 0 ]] 2>/dev/null || { echo "gap-report-consistency: no closed rows parsed; the table shape changed" >&2; exit 2; }

echo "gap-report-consistency: derived -> $counts"

# Each severity the tables still carry must be claimed by the summary with the
# same number. `- **high (0).**` and `- **med (1 remaining):**` both parse.
bad=0
for sev in high med low open blocked; do
  actual=$(grep -oE "(^| )$sev=[0-9]+" <<<"$counts" | grep -oE '[0-9]+$')
  actual=${actual:-0}
  claimed=$(grep -oE "^- \*\*$sev \(([0-9]+)" "$REPORT" | grep -oE '[0-9]+$' | head -1)
  if [[ -z "$claimed" ]]; then
    if (( actual > 0 )); then
      echo "  $sev: tables hold $actual row(s) and the summary does not mention $sev at all" >&2
      bad=$((bad+1))
    fi
    continue
  fi
  if (( claimed != actual )); then
    echo "  $sev: summary claims $claimed, tables hold $actual" >&2
    bad=$((bad+1))
  fi
done

if (( bad > 0 )); then
  echo "gap-report-consistency: the summary and the tables disagree." >&2
  echo "  The summary is what gets read. Update it, or the report misstates its own gaps." >&2
  exit 1
fi
echo "gap-report-consistency: summary agrees with the tables"
