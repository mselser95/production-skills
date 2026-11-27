#!/usr/bin/env bash
# usage: solve.sh <workdir> <agent-output-file>
# Writes the structured review a correct reviewer returns (output.schema.json).
set -eu
[ "$#" -eq 2 ] || { echo "usage: solve.sh <workdir> <agent-output-file>" >&2; exit 2; }
cat > "$2" <<'REVIEW_EOF'
{
  "verdict": "defects_found",
  "findings": [
    {
      "file": "invoicing/lines.py",
      "line_start": 35,
      "line_end": 35,
      "class": "defect",
      "severity": "blocker",
      "summary": "Tax is quantized with the default rounding (half-even), not the half-up to_cents policy, so a line whose tax lands on a half cent is rounded to the wrong cent."
    },
    {
      "file": "tests/test_lines.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed code."
    }
  ]
}
REVIEW_EOF
