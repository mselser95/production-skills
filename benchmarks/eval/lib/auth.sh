#!/usr/bin/env bash
# auth.sh -- sourced. Credential lookup for the claude host, in ONE place.
# Every line that touches a credential runs with xtrace OFF, so `bash -x` on an
# adapter cannot print it; the previous xtrace state is restored afterwards.
#
# eval_claude_auth -> 0 and EVAL_AUTH_VAR=<name of the exported auth variable>,
#                     1 when no credential could be found (caller exits 78).
# Order: exported CLAUDE_CODE_OAUTH_TOKEN, exported ANTHROPIC_API_KEY (the
# documented headless paths), then -- only if neither is set -- the ACCESS token
# (never the refresh token, so a run cannot rotate the user's login) from the
# real config dir's .credentials.json or the macOS keychain item
# "Claude Code-credentials-<sha256($REAL)[:8]>". $REAL = EVAL_CLAUDE_AUTH_DIR,
# else CLAUDE_CONFIG_DIR, else ~/.claude. The keychain is read through the
# `security` binary found on PATH; tests put a fake `security` first on PATH.
# No environment value is ever evaluated as code.

# shellcheck disable=SC2034  # EVAL_AUTH_VAR is read by the sourcing adapter
# shellcheck source=sha256.sh
source "$(dirname "${BASH_SOURCE[0]}")/sha256.sh"
_eval_claude_auth_inner() {
  local real creds="" tok="" sfx lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  EVAL_AUTH_VAR=""
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then EVAL_AUTH_VAR=CLAUDE_CODE_OAUTH_TOKEN; return 0; fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then EVAL_AUTH_VAR=ANTHROPIC_API_KEY; return 0; fi
  real="${EVAL_CLAUDE_AUTH_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  if [[ -r "$real/.credentials.json" ]]; then
    creds="$(cat "$real/.credentials.json")"
  elif [[ "$(uname)" == Darwin ]] && command -v security >/dev/null 2>&1; then
    sfx="$(printf %s "$real" | eval_sha256 | cut -c1-8)"
    creds="$(python3 -I -B "$lib/limited.py" 20 -- security find-generic-password -s "Claude Code-credentials-$sfx" -w 2>/dev/null)" || creds=""
    if [[ -z "$creds" && "$real" == "$HOME/.claude" ]]; then
      creds="$(python3 -I -B "$lib/limited.py" 20 -- security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" || creds=""
    fi
  fi
  tok="$(printf %s "$creds" | python3 -I -B -c 'import json,sys
try: print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception: pass' 2>/dev/null)"
  creds=""
  [[ -n "$tok" ]] || return 1
  export CLAUDE_CODE_OAUTH_TOKEN="$tok"
  tok=""
  EVAL_AUTH_VAR=CLAUDE_CODE_OAUTH_TOKEN
  return 0
}

eval_claude_auth() {
  local xt=0 rc
  case $- in *x*) xt=1 ;; esac
  { set +x; } 2>/dev/null
  _eval_claude_auth_inner; rc=$?
  if [[ $xt -eq 1 ]]; then set -x; fi
  return $rc
}
