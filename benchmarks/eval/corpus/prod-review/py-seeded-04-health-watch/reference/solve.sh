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
      "file": "poller/probe.py",
      "line_start": 50,
      "line_end": 52,
      "class": "defect",
      "severity": "blocker",
      "summary": "Catching CancelledError and returning swallows cancellation: task.cancel() or an outer timeout ends the watch as a normal return, never as a cancelled task."
    },
    {
      "file": "tests/test_probe.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed code."
    }
  ]
}
REVIEW_EOF
