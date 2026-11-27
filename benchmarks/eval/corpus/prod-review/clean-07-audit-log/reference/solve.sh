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
      "file": "file.go",
      "line_start": 14,
      "line_end": 20,
      "class": "note",
      "severity": "nit",
      "summary": "The deferred close ignores its error on purpose: the primary error is already being returned."
    },
    {
      "file": "log_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers a destination whose Write or Close fails."
    }
  ]
}
REVIEW_EOF
