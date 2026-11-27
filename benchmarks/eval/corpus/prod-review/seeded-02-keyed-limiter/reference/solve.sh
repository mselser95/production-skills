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
      "file": "keyed.go",
      "line_start": 23,
      "line_end": 25,
      "class": "defect",
      "severity": "blocker",
      "summary": "limiterFor reads the map without holding the mutex, which races with the locked write below it."
    },
    {
      "file": "limiter_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed path."
    }
  ]
}
REVIEW_EOF
