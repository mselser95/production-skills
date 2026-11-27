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
      "file": "upload.go",
      "line_start": 1,
      "line_end": 1,
      "class": "note",
      "severity": "nit",
      "summary": "New now returns ErrTotal only for a negative total."
    },
    {
      "file": "upload_test.go",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "nit",
      "summary": "No test covers a short last chunk, an empty upload or Received."
    }
  ]
}
REVIEW_EOF
