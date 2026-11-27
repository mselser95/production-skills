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
      "file": "shutdown.go",
      "line_start": 13,
      "line_end": 14,
      "class": "note",
      "severity": "nit",
      "summary": "The result channel is buffered so the waiter goroutine can always send and exit, even after Shutdown returned on the deadline."
    },
    {
      "file": "drain_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers Shutdown draining, hitting its deadline, or being called twice."
    }
  ]
}
REVIEW_EOF
