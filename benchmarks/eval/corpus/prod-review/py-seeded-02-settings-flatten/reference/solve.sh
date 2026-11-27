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
      "file": "settings/sources.py",
      "line_start": 33,
      "line_end": 38,
      "class": "defect",
      "severity": "blocker",
      "summary": "The accumulator default `out={}` is one dict shared by every call, so a second from_toml returns the keys of the first as well."
    },
    {
      "file": "tests/test_settings.py",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The existing tests never reach the changed code."
    }
  ]
}
REVIEW_EOF
