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
      "file": "publish.go",
      "line_start": 12,
      "line_end": 16,
      "class": "note",
      "severity": "nit",
      "summary": "The lock is released before handlers run, on a copied slice, so handlers can re-enter the bus; this is deliberate and correct."
    },
    {
      "file": "bus_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers Publish, PublishAsync or a handler that unsubscribes itself."
    }
  ]
}
REVIEW_EOF
