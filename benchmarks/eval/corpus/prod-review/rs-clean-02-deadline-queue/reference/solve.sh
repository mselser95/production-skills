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
      "file": "src/queue.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "note",
      "severity": "nit",
      "summary": "The ignored send result is a wake-up hint; a missing receiver loses nothing."
    },
    {
      "file": "src/queue.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test exercises the new code from several threads or at the numeric limits."
    }
  ]
}
REVIEW_EOF
