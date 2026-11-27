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
      "file": "src/frame.rs",
      "line_start": 35,
      "line_end": 35,
      "class": "defect",
      "severity": "blocker",
      "summary": "`payload.len() as u16` truncates silently for payloads over 65535 bytes, so the length prefix no longer matches the body and the frame cannot be decoded; it needs `u16::try_from` and an error."
    },
    {
      "file": "src/frame.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The tests never reach the changed path that fails."
    }
  ]
}
REVIEW_EOF
