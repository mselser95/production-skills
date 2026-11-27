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
      "file": "ops.go",
      "line_start": 5,
      "line_end": 8,
      "class": "note",
      "severity": "nit",
      "summary": "A lease expiring exactly at now counts as expired; Acquire, Renew and Release all decide through live, so the boundary is consistent."
    },
    {
      "file": "keeper_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers Acquire, Renew or Release at the expiry boundary."
    }
  ]
}
REVIEW_EOF
