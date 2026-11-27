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
      "file": "cmdrun/runner.py",
      "line_start": 1,
      "line_end": 1,
      "class": "note",
      "severity": "nit",
      "summary": "The broad except re-raises after killing the child, so it only adds cleanup."
    },
    {
      "file": "tests/test_runner.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers the new function."
    }
  ]
}
REVIEW_EOF
