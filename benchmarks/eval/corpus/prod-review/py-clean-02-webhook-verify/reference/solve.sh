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
      "file": "webhooks/signing.py",
      "line_start": 1,
      "line_end": 1,
      "class": "note",
      "severity": "nit",
      "summary": "The comparison already uses hmac.compare_digest on bytes; the list-then-any shape only avoids short-circuiting."
    },
    {
      "file": "tests/test_signing.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers the new function."
    }
  ]
}
REVIEW_EOF
