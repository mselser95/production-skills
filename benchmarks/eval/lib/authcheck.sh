#!/usr/bin/env bash
# authcheck.sh <claude|codex> -- is a usable credential available? Prints
# "ok" / "missing" only, never a credential. Exit 0 ok | 78 missing | 2 usage.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  claude)
    # shellcheck source=auth.sh
    source "$here/auth.sh"
    if eval_claude_auth; then echo ok; exit 0; fi
    echo missing; exit 78 ;;
  codex)
    if [[ -n "${CODEX_API_KEY:-}" || -f "${EVAL_CODEX_REAL_HOME:-$HOME/.codex}/auth.json" ]]; then echo ok; exit 0; fi
    echo missing; exit 78 ;;
  stub) echo ok; exit 0 ;;   # the selftest's fake host needs no credential
  *) echo "usage: authcheck.sh claude|codex" >&2; exit 2 ;;
esac
