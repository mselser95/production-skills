#!/usr/bin/env bash
# monorepo-settings-check.sh [ROOT] -- the monorepo root's static gate. Exit 0 clean, 1 findings
# (one `file:line: RULE message` per finding), 2 cannot run (no PyYAML, no python3).
# PYTHON=<interpreter> overrides python3. No network, no pnpm needed (it asks `make -n` per unit).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$here/.." && pwd)}"
py="${PYTHON:-python3}"
# Layout guard: this module is monorepo-only (its manifest cannot say so), so a root without the pair is no monorepo.
if [[ ! -f "$root/pnpm-workspace.yaml" || ! -f "$root/repo.yaml" ]]; then
  echo "FAIL monorepo-settings-check: $root has no pnpm-workspace.yaml + repo.yaml pair; this module is for layout monorepo only"
  exit 1
fi
exec "$py" -B "$here/monorepo_check.py" check "$root"
