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
# Exit 78 = no credential; exit 79 = no usable sandbox (run.sh records error "sandbox").
#
# Confinement: the SAME macOS seatbelt profile as the claude adapter (`sandbox-exec -f <profile>`,
# generated per cell by lib/seatbelt.py: user data default-deny for read AND write, re-allowed only for
# the cell's home / GOCACHE / TMPDIR, the workdir (read; write only in workspace-write) and the dir of
# the real `codex` binary; the repo, the task dir and the REAL Codex home are denied again at the end).
# Codex's own sandbox is switched off in that configuration (`-s danger-full-access`, because it cannot
# nest its own seatbelt inside ours) and approvals never prompt (`-c approval_policy=never`):
# `danger-full-access` is passed ONLY when the outer wrapper is present. The real binary normally lives
# under the real Codex home (next to auth.json): only its `bin/` dir is re-allowed (`--reallow-read`,
# found by trial: `codex --version` starts with just that dir), the rest of that home stays denied.
# No sandbox-exec / not Darwin -> exit 79, never a silent unconfined run. The ONE opt-out is
# EVAL_NO_SANDBOX=1 (host-neutral name): Codex then runs under its OWN `-s workspace-write` sandbox,
# which (both agent modes; Codex has no read-only mode that lets `go build` write its cache) confines
# WRITES to the workdir plus the per-cell GOCACHE (--add-dir) but NOT reads (the answer
# key and the user's files are readable); loud warning, row sandbox:"codex". Selftest-only 10th/11th
# arguments `--deny-roots a:b` replace the denied roots (as in claude.sh); run.sh never passes them.
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
denyroots=""; if [[ "${10:-}" == --deny-roots ]]; then denyroots="${11:-}"; fi
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
sbxdir=""
cleanup() { finish_auth; [[ -n "$sbxdir" ]] && rm -rf "$sbxdir"; return 0; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

gc="${EVAL_GOCACHE:-$home/gocache}"; celltmp="${EVAL_CELL_TMPDIR:-$home/tmp}"
sb_exec=() sandboxed=0 codex_bin=codex
if [[ "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then
  echo "codex.sh: WARNING: EVAL_NO_SANDBOX=1 -- codex runs under its OWN workspace-write sandbox: writes are confined, READS ARE NOT (the corpus answer key and the user's files are readable; row sandbox:codex); results are not comparable with seatbelt rows" >&2
else
  if [[ "$(uname)" != Darwin ]]; then
    echo "codex.sh: no seatbelt sandbox on $(uname) -- refusing an unconfined run (error: sandbox). Live codex runs are macOS-only unless EVAL_NO_SANDBOX=1." >&2; exit 79
  fi
  sbx="$(command -v sandbox-exec)" || { echo "codex.sh: sandbox-exec not found; refusing an unconfined run (error: sandbox). Set EVAL_NO_SANDBOX=1 to opt out explicitly." >&2; exit 79; }
  sbxdir="$(mktemp -d "$(dirname "$home")/sbx.XXXXXX")" || { sbxdir=""; echo "codex.sh: cannot create the sandbox profile dir (error: sandbox)" >&2; exit 79; }
  profile="$sbxdir/p.sb"
  rp() { python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }
  repo_root="$(cd "$here/../../.." && pwd)"
  sb_args=()
  if cx="$(command -v codex)" && [[ -n "$cx" ]]; then
    codex_bin="$(rp "$cx")"; bindir="$(dirname "$codex_bin")"; rreal="$(rp "$real")"
    if [[ "$bindir" == "$rreal"/* ]]; then sb_args+=(--reallow-read "$bindir")   # install dir inside the denied real Codex home: that ONE dir
    else sb_args+=(--allow-read "$bindir"); fi
  fi
  # codex READS the --output-schema file itself (claude gets the schema inline): that ONE file sits in the corpus
  # (under the denied repo / temp roots), so it is re-allowed after the denies. Never its directory.
  [[ -n "$schema" ]] && sb_args+=(--reallow-read "$schema")
  goroot="$(GOTOOLCHAIN=local go env GOROOT 2>/dev/null)" && [[ -n "$goroot" ]] && sb_args+=(--allow-read "$goroot")
  gx="$(git --exec-path 2>/dev/null)" && [[ -n "$gx" ]] && sb_args+=(--allow-read "$gx")
  # denied AGAIN after the re-allows: the repo (answer key, .git object store), the REAL Codex home (auth, config), the profile dir
  sb_args+=(--deny-read "$repo_root" --deny-read "$real" --protect "$sbxdir")
  [[ -n "${EVAL_TASK_DIR:-}" ]] && sb_args+=(--protect "$EVAL_TASK_DIR")
  if [[ -n "$denyroots" ]]; then
    IFS=: read -r -a dr <<<"$denyroots"
    for r in "${dr[@]}"; do [[ -n "$r" ]] && sb_args+=(--deny-root "$r"); done
  fi
  python3 -I -B "$here/../lib/seatbelt.py" "$workdir" "$home" "$gc" "$celltmp" "$mode" "${sb_args[@]}" >"$profile" || { echo "codex.sh: cannot build the sandbox profile (error: sandbox)" >&2; exit 79; }
  "$sbx" -f "$profile" /usr/bin/true >/dev/null 2>&1 || { echo "codex.sh: the sandbox profile does not run (error: sandbox)" >&2; exit 79; }
  sb_exec=("$sbx" -f "$profile"); sandboxed=1
fi

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

mkdir -p "$gc"
raw="$home/.eval-codex.jsonl"
args=(exec --json --skip-git-repo-check --ignore-user-config -C "$workdir" --ephemeral)
if [[ $sandboxed -eq 1 ]]; then   # the outer seatbelt is the sandbox; danger-full-access ONLY in this branch
  args+=(-s danger-full-access -c approval_policy=never)
else
  args+=(-s workspace-write --add-dir "$gc")
fi
[[ -n "$model" ]] && args+=(-m "$model")
last=""
if [[ -n "$schema" ]]; then last="$home/.eval-codex-last.txt"; args+=(--output-schema "$schema" -o "$last"); fi
python3 -I -B "$here/../lib/runenv.py" --cwd "$workdir" --home "$home" --gocache "$gc" --tmpdir "$celltmp" \
  --set "CODEX_HOME=$home" ${auth_pass[@]+"${auth_pass[@]}"} -- ${sb_exec[@]+"${sb_exec[@]}"} "$codex_bin" "${args[@]}" - <"$prompt" >"$raw" 2>"$home/.eval-codex.err"
rc=$?
finish_auth
if [[ -s "$home/.eval-codex.err" ]]; then tail -n 5 "$home/.eval-codex.err" | cut -c1-200 >&2; fi
python3 -I -B "$here/../lib/parse_codex.py" "$raw" "$out" "$usage" ${last:+"$last"} || { [[ $rc -eq 0 ]] && rc=3; }
exit "$rc"
