#!/usr/bin/env bash
# instantiate-template.sh <dest-dir> [service] [owner] -- turn prod-new/template/ into a repo.
# A thin wrapper: scripts/assemble.py (--layout single --module service-go) is the ONE
# implementation, so value grammar, .git refusal, modes, atomicity and signals live there.
# Omitted service/owner default to svc / mselser95; an explicit empty one is exit 2.
# Exit: 0 done - 1 refused source/dest - 2 usage, bad value, unreadable source.
set -uo pipefail
USAGE="usage: instantiate-template.sh <dest-dir> [service] [owner]  (values: 1-64 chars, [A-Za-z0-9][A-Za-z0-9._-]*, never empty)"
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then echo "$USAGE"; exit 0; fi
(( $# >= 1 && $# <= 3 )) && [[ -n "$1" ]] || { echo "$USAGE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "instantiate: python3 not found" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I -B "$here/assemble.py" --layout single --module service-go --dest="$1" \
  --slot="SERVICE=${2-svc}" --slot="OWNER=${3-mselser95}"
