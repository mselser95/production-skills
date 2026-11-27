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
      "file": "fetch.go",
      "line_start": 102,
      "line_end": 104,
      "class": "defect",
      "severity": "blocker",
      "summary": "The backoff sleep ignores ctx, so after a cancel Fetch still blocks for the whole wait before the next ctx check."
    },
    {
      "file": "fetch_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "No test covers WithBackoff or cancelling during a wait."
    }
  ]
}
REVIEW_EOF
