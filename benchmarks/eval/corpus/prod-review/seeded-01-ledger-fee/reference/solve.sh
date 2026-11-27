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
      "file": "ledger.go",
      "line_start": 66,
      "line_end": 68,
      "class": "defect",
      "severity": "blocker",
      "summary": "The fee-account credit ignores the Put error and the Get error, so a failed write destroys the fee after the sender was already debited."
    },
    {
      "file": "ledger_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed path."
    }
  ]
}
REVIEW_EOF
