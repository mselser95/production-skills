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
      "file": "importer.go",
      "line_start": 46,
      "line_end": 48,
      "class": "defect",
      "severity": "blocker",
      "summary": "A failed Put is dropped with continue: it is not counted, not returned and not in Result, so a partly stored import reports success."
    },
    {
      "file": "importer_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never make the store fail."
    }
  ]
}
REVIEW_EOF
