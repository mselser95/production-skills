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
      "file": "src/store.rs",
      "line_start": 61,
      "line_end": 61,
      "class": "defect",
      "severity": "blocker",
      "summary": "`put_bounded` calls `self.len()` while the `inner` guard is still held; `len` locks the same non-re-entrant mutex, so a full store deadlocks instead of returning `Full`."
    },
    {
      "file": "src/store.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The tests never reach the changed path that fails."
    }
  ]
}
REVIEW_EOF
