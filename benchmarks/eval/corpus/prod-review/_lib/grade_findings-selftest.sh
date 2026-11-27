#!/usr/bin/env bash
# Thin wrapper: the cases live in grade_findings_selftest.py (in-process, fast).
# GRADE_PY=<path> grades with another copy of the grader (mutation proofs);
# --mutations runs every mutation against a temp copy and prints one RED/GREEN line each.
set -u
here=$(cd "$(dirname "$0")" && pwd)
exec python3 -I "$here/grade_findings_selftest.py" "$@"
