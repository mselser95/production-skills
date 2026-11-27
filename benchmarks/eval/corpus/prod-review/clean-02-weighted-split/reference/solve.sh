#!/usr/bin/env bash
# usage: solve.sh <workdir> <agent-output-file>
# Writes the structured review a correct reviewer returns (output.schema.json).
set -eu
[ "$#" -eq 2 ] || { echo "usage: solve.sh <workdir> <agent-output-file>" >&2; exit 2; }
cat > "$2" <<'REVIEW_EOF'
{
  "verdict": "no_defects",
  "findings": [
    {
      "file": "split.go",
      "line_start": 1,
      "line_end": 1,
      "class": "note",
      "severity": "nit",
      "summary": "The leftover loop terminates because the leftover is smaller than the number of positive weights."
    },
    {
      "file": "split_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers the overflow guard or a zero-weight party."
    }
  ]
}
REVIEW_EOF
