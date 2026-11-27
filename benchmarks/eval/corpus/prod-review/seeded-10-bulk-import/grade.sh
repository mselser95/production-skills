#!/usr/bin/env bash
# usage: grade.sh <workdir> <agent-output-file>
set -u
[ "$#" -eq 2 ] || { echo "usage: grade.sh <workdir> <agent-output-file>" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
python3 -I "${GRADE_PY:-$here/../_lib/grade_findings.py}" --workdir "$1" --output "$2" \
  --expected "$here/expected.diffhash" --file importer.go --start 46 --end 48
