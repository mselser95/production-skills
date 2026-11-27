#!/usr/bin/env bash
# codex.sh -- Codex CLI adapter. Contract:
#   <workdir> <host-home> <prompt-file> <output-file> <usage-json> <model> <budget-usd> <agent_mode> [<schema-file>]
# <schema-file> (9th, optional, "" = none) is corpus/<skill>/_lib/output.schema.json when the
# skill has one (run.sh decides). Present -> `--output-schema <file>` and `-o <home>/.eval-codex-last.txt`
# (`codex exec --help`: --output-schema "Path to a JSON Schema file describing the model's final
# response shape"; -o/--output-last-message "file where the last message from the agent should be
# written"). The final message is the document; lib/parse_codex.py prefers the -o file and falls
# back to the last agent_message item of the JSONL.
# STDIN: `codex exec [PROMPT]` reads stdin when the prompt is `-` or absent, and appends it as a
# <stdin> block when it is piped; on a pipe that never closes it prints "Reading additional input
# from stdin..." and hangs. The prompt is passed as `-` with stdin redirected FROM THE PROMPT FILE,
# so stdin is always a regular file at EOF, whatever the caller's stdin is (selftest 19h).
# Exit 78 = no credential. Both agent modes run `-s workspace-write`: the OS
# sandbox confines writes to the workdir plus the per-cell GOCACHE (--add-dir);
# Codex has no read-only mode that still lets `go build` write its cache.
#
# Isolation: lib/runenv.py (no inherited environment; HOME and CODEX_HOME = the
# throwaway <host-home>; cwd = workdir). Auth: an exported CODEX_API_KEY is
# preferred; else the real auth.json is COPIED (mode 600) into the isolated
# home. Codex may rotate the refresh token inside the copy, so after the run a
# changed copy is written back to the real file (atomic, 600, only if the real
# file is still what we copied) or the user's real login would be invalidated.
# The copy is deleted on every exit path, signals included. Never printed.
# LIMITS of the write-back (compare-then-rename, not a lock): there is a TOCTOU
# window between the comparison and the rename; a token rotated right before a
# SIGKILL (limited.py's last resort) is lost; and a concurrent interactive
# `codex` can invalidate the refresh token under us. For unattended live runs
# export CODEX_API_KEY instead: then no auth.json is touched at all.
# <budget-usd> is NOT enforced: codex has no spend cap; only timeout_s binds.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
workdir="$1" home="$2" prompt="$3" out="$4" usage="$5" model="${6:-}" _budget="${7:-1}" mode="${8:-read-only}" schema="${9:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/sha256.sh
source "$here/../lib/sha256.sh"
case "$mode" in read-only|workspace-write) ;; *) echo "codex.sh: unknown agent_mode '$mode'" >&2; exit 2 ;; esac

real="${EVAL_CODEX_REAL_HOME:-$HOME/.codex}"
copy="$home/auth.json" start_sha="" auth_pass=()
finish_auth() { # write a rotated copy back, then scrub the copy. Idempotent.
  { set +x; } 2>/dev/null
  if [[ -f "$copy" ]]; then
    local now cur d t
    now="$(eval_sha256 <"$copy")"
    cur="$(eval_sha256 <"$real/auth.json" 2>/dev/null)"
    if [[ -n "$start_sha" && "$now" != "$start_sha" && "$cur" == "$start_sha" ]]; then
      d="$(dirname "$real/auth.json")"
      t="$(umask 077; mktemp "$d/.auth.XXXXXX")" && { cat "$copy" >"$t"; chmod 600 "$t"; mv -f "$t" "$real/auth.json"; }
    fi
    rm -f "$copy"
  fi
}
trap finish_auth EXIT
trap 'exit 143' TERM INT HUP

if [[ -n "${CODEX_API_KEY:-}" ]]; then
  auth_pass=(--pass CODEX_API_KEY)
elif [[ -f "$real/auth.json" ]]; then
  { set +x; } 2>/dev/null
  ( umask 077; cp "$real/auth.json" "$copy" ) || { echo "codex.sh: cannot stage auth" >&2; exit 78; }
  chmod 600 "$copy"
  start_sha="$(eval_sha256 <"$copy")"
else
  echo "codex.sh: no usable credential (auth)" >&2; exit 78
fi

gc="${EVAL_GOCACHE:-$home/gocache}"; mkdir -p "$gc"
raw="$home/.eval-codex.jsonl"
args=(exec --json --skip-git-repo-check --ignore-user-config -C "$workdir" -s workspace-write --add-dir "$gc" --ephemeral)
[[ -n "$model" ]] && args+=(-m "$model")
last=""
if [[ -n "$schema" ]]; then last="$home/.eval-codex-last.txt"; args+=(--output-schema "$schema" -o "$last"); fi
python3 -I -B "$here/../lib/runenv.py" --cwd "$workdir" --home "$home" --gocache "$gc" --tmpdir "${EVAL_CELL_TMPDIR:-$home/tmp}" \
  --set "CODEX_HOME=$home" ${auth_pass[@]+"${auth_pass[@]}"} -- codex "${args[@]}" - <"$prompt" >"$raw" 2>"$home/.eval-codex.err"
rc=$?
finish_auth
if [[ -s "$home/.eval-codex.err" ]]; then tail -n 5 "$home/.eval-codex.err" | cut -c1-200 >&2; fi
python3 -I -B "$here/../lib/parse_codex.py" "$raw" "$out" "$usage" ${last:+"$last"} || { [[ $rc -eq 0 ]] && rc=3; }
exit "$rc"
