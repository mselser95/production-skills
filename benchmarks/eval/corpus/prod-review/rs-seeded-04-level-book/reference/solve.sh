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
      "file": "src/book.rs",
      "line_start": 55,
      "line_end": 57,
      "class": "defect",
      "severity": "blocker",
      "summary": "`zip` stops at the shorter list and the lengths are never compared, so a replica missing its deeper levels is reported as having the same top."
    },
    {
      "file": "src/book.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The tests never reach the changed path that fails."
    }
  ]
}
REVIEW_EOF
