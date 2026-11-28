#!/usr/bin/env bash
# monorepo-settings-check.sh [ROOT] -- the monorepo root's static gate. Exit 0 clean, 1 findings
# (one `file:line: RULE message` per finding), 2 cannot run (no PyYAML, no python3).
# PYTHON=<interpreter> overrides python3. No network, no pnpm needed.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$here/.." && pwd)}"
py="${PYTHON:-python3}"
exec "$py" -B "$here/monorepo_check.py" check "$root"
