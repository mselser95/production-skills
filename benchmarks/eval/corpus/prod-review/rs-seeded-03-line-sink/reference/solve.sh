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
      "file": "src/sink.rs",
      "line_start": 34,
      "line_end": 34,
      "class": "defect",
      "severity": "blocker",
      "summary": "The result of `self.out.flush()` is discarded with `let _ =`, so a failed flush leaves the batch undelivered while `write_batch` returns `Ok(n)` and counts it as written."
    },
    {
      "file": "src/sink.rs",
      "line_start": 1,
      "line_end": 1,
      "class": "missing_test",
      "severity": "warning",
      "summary": "The tests never reach the changed path that fails."
    }
  ]
}
REVIEW_EOF
