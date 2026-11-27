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
      "file": "windows/labels.py",
      "line_start": 25,
      "line_end": 25,
      "class": "defect",
      "severity": "blocker",
      "summary": "datetime.now() is naive local time and as_utc takes a naive timestamp to be UTC, so on a host not set to UTC the hour label is shifted by the host offset."
    },
    {
      "file": "tests/test_windows.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed code."
    }
  ]
}
REVIEW_EOF
