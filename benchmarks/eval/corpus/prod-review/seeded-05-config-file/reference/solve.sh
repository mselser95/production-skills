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
      "file": "config.go",
      "line_start": 82,
      "line_end": 83,
      "class": "defect",
      "severity": "blocker",
      "summary": "The file is not closed when Parse fails, so the handle leaks on the error path."
    },
    {
      "file": "config_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed path."
    }
  ]
}
REVIEW_EOF
