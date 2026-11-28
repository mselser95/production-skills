#!/usr/bin/env bash
# codex.sh -- Codex CLI adapter. Contract:
#   <workdir> <host-home> <prompt-file> <output-file> <usage-json> <model> <budget-usd> <agent_mode> [<schema-file>]
# <schema-file> (9th, optional, "" = none) is corpus/<skill>/_lib/output.schema.json when the
# skill has one (run.sh decides). Present -> `--output-schema <file>` (`codex exec --help`: "Path to a JSON
# Schema file describing the model's final response shape"). The answer and the usage are parsed from the
# `--json` EVENT STREAM the adapter captured on stdout (lib/parse_codex.py: the last agent_message item, the
# summed turn.completed usage). `-o/--output-last-message` is NOT passed and no file inside the cell is ever
# read back: the agent writes the cell home, so such a file could be forged (selftest 19x).
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
# throwaway <host-home>; cwd = workdir; TMPDIR = the cell tmp). CREDENTIAL CONTRACT (nothing leaves the cell):
#  - an exported CODEX_API_KEY is preferred and passed by name: no file at all;
#  - else the real <real home>/auth.json is COPIED into the cell home, once, before the CLI starts: opened with
#    O_NOFOLLOW (a symlink or a non-regular file is refused, exit 78), written to a NEW file (O_EXCL) mode 0600;
#  - it is NEVER written back. The sandboxed agent controls the cell home, so anything copied out of it would let
#    the model choose the bytes of the user's real login (history: selftest 14v / README "Write-back"). If Codex
#    rotates its refresh token during a cell the real file may be left stale: log in again, or export
#    CODEX_API_KEY. Opt-in EVAL_CODEX_AUTH_READONLY=1 (sandboxed only) additionally makes the staged copy
#    unwritable for the agent so Codex cannot rotate inside a cell (selftest 14v3; whether Codex starts with a
#    read-only auth file is NOT VALIDATED without a model run, hence off by default);
#  - the copy is scrubbed after the CLI exits and on EXIT/TERM/INT/HUP (not SIGKILL: run.sh's startup sweep), by the sequence
#    documented at scrub_auth below (permission reset, wipe through a held fd, unlink, verify; exit 80 on failure). Never printed.
# Exit 80 = scrub failed; 81 = a process outlived the CLI holding its stdout (orphan-process); 82 = stream-trailing-data.
# <budget-usd> is NOT enforced: codex has no spend cap; only timeout_s binds.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
workdir="$1" home="$2" prompt="$3" out="$4" usage="$5" model="${6:-}" _budget="${7:-1}" mode="${8:-read-only}" schema="${9:-}"
denyroots=""; if [[ "${10:-}" == --deny-roots ]]; then denyroots="${11:-}"; fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$mode" in read-only|workspace-write) ;; *) echo "codex.sh: unknown agent_mode '$mode'" >&2; exit 2 ;; esac

real="${EVAL_CODEX_REAL_HOME:-$HOME/.codex}"
copy="$home/auth.json" auth_pass=() runpid="" sbxdir="" staged=0 scrub_failed=0
scrubpy="$here/../lib/scrub.py" redactpy="$here/../lib/redact.py"
# SECRET SET (README "Credentials"): what run.sh must find nowhere in the row, the captures or the kept files. Written to
# $EVAL_SECRETS_FILE (run.sh's 0600 file in the cell root) at staging: the staged copy's bytes and every JSON string value >= 16 chars in
# it, or the value of CODEX_API_KEY (through a pipe, with the variable removed from the helper's environment: never argv, never env).
# No file, no setting: the caller is not run.sh (selftests of the adapter). Failure to record it is a credential failure (exit 78).
# SCRUB SEQUENCE (the credential copy never outlives the CLI; nothing is ever copied back out): (1) close the control FIFO:
# the holder started at staging wipes the STAGED INODE through the descriptor it kept open (zeros, ftruncate, fsync), which
# destroys the bytes for every hard link under any name or directory permission; (2) wait (bounded) for it; (3) reset
# permissions/immutable flags of the agent-writable home from outside (the agent may have chmod 000 / chflags uchg);
# (4) unlink BY NAME through a directory-descriptor walk (lib/scrub.py rmname: every component opened O_NOFOLLOW|O_DIRECTORY,
# permissions and flags reset on the way, so a home the agent replaced by a symlink is unlinked as a name and its target is
# never touched; the name is recorded in <cell>/cell-tampered for run.sh); (5) verify the name is gone, else scrub_failed (exit 80).
# run.sh then removes the whole cell.
scrub_auth() {
  { set +x; } 2>/dev/null
  [[ $staged -eq 1 ]] || return 0
  exec 9>&-
  [[ -s "$sbxdir/holder.pid" ]] && python3 -I -B "$scrubpy" waitgone "$sbxdir/holder.pid" 5
  local o rc
  o="$(python3 -I -B "$scrubpy" rmname "$(dirname "$home")" "$(basename "$home")/auth.json" 2>&1)"; rc=$?
  if [[ "$o" == *"tampered "* ]]; then
    printf '%s\n' "$(printf '%s\n' "$o" | sed -n 's/^tampered //p' | head -n 1)" >>"$(dirname "$home")/cell-tampered"
    echo "codex.sh: CELL TAMPERED (error: cell-tampered): the agent replaced a name the credential copy lives under; the name was unlinked, its target untouched" >&2
  fi
  if [[ $rc -ne 0 ]]; then
    scrub_failed=1
    echo "codex.sh: SCRUB FAILED: the credential copy is still on disk at $copy (its content was wiped through the held descriptor, the name was not removable); remove $(dirname "$home") by hand" >&2
  fi
  staged=0
}
cleanup() {
  if [[ -n "$runpid" ]]; then kill -TERM "$runpid" 2>/dev/null; wait "$runpid" 2>/dev/null; runpid=""; fi
  scrub_auth
  [[ -n "$sbxdir" ]] && python3 -I -B "$scrubpy" rmcell "$sbxdir" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT
trap 'exit 129' HUP   # `wait` below (not a foreground child) lets the trap fire at once; the EXIT trap scrubs
# the adapter's own dir, in the cell's temp root next to the home: the profile (sandboxed) and the CLI's captured
# stdout/stderr live here. The profile never re-allows it, so the agent cannot read, forge or replace them.
sbxdir="$(mktemp -d "$(dirname "$home")/sbx.XXXXXX")" || { sbxdir=""; echo "codex.sh: cannot create the adapter dir (error: sandbox)" >&2; exit 79; }

gc="${EVAL_GOCACHE:-$home/gocache}"; celltmp="${EVAL_CELL_TMPDIR:-$home/tmp}"
sb_exec=() sandboxed=0 codex_bin=codex
if [[ "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then
  echo "codex.sh: WARNING: EVAL_NO_SANDBOX=1 -- codex runs under its OWN workspace-write sandbox: writes are confined, READS ARE NOT (the corpus answer key and the user's files are readable; row sandbox:codex); results are not comparable with seatbelt rows" >&2
else
  if [[ "$(uname)" != Darwin ]]; then
    echo "codex.sh: no seatbelt sandbox on $(uname) -- refusing an unconfined run (error: sandbox). Live codex runs are macOS-only unless EVAL_NO_SANDBOX=1." >&2; exit 79
  fi
  sbx="$(command -v sandbox-exec)" || { echo "codex.sh: sandbox-exec not found; refusing an unconfined run (error: sandbox). Set EVAL_NO_SANDBOX=1 to opt out explicitly." >&2; exit 79; }
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
  [[ "${EVAL_CODEX_AUTH_READONLY:-0}" == 1 ]] && sb_args+=(--readonly-file "$copy")
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
  if [[ -n "${EVAL_SECRETS_FILE:-}" ]]; then
    { set +x; } 2>/dev/null
    printf %s "$CODEX_API_KEY" | env -u CODEX_API_KEY python3 -I -B "$redactpy" add-stdin "$EVAL_SECRETS_FILE" || { echo "codex.sh: cannot record the secret set (credential)" >&2; exit 78; }
  fi
elif [[ -e "$real/auth.json" || -L "$real/auth.json" ]]; then
  { set +x; } 2>/dev/null
  # lib/scrub.py hold: O_NOFOLLOW + regular-file check + a NEW file (O_EXCL) at 0600; the content is never inspected or
  # printed; the staged inode's descriptor stays open in a small holder process until the scrub (see scrub_auth)
  staged=1
  python3 -I -B "$scrubpy" hold "$real/auth.json" "$copy" "$sbxdir/ctl" "$sbxdir/holder.pid" || { scrub_auth; echo "codex.sh: cannot stage auth (credential)" >&2; exit 78; }
  if [[ -n "${EVAL_SECRETS_FILE:-}" ]]; then
    env -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN python3 -I -B "$redactpy" add-json-file "$EVAL_SECRETS_FILE" "$copy" || { scrub_auth; echo "codex.sh: cannot record the secret set (credential)" >&2; exit 78; }
  fi
  exec 9>"$sbxdir/ctl"   # our end of the holder's control FIFO: closing it (or dying) makes the holder wipe
else
  echo "codex.sh: no usable credential (auth)" >&2; exit 78
fi

mkdir -p "$gc"
raw="$sbxdir/events.jsonl" errf="$sbxdir/stderr.txt"   # opened HERE, outside the cell: the CLI inherits the descriptors
args=(exec --json --skip-git-repo-check --ignore-user-config -C "$workdir" --ephemeral)
if [[ $sandboxed -eq 1 ]]; then   # the outer seatbelt is the sandbox; danger-full-access ONLY in this branch
  args+=(-s danger-full-access -c approval_policy=never)
else
  args+=(-s workspace-write --add-dir "$gc")
fi
[[ -n "$model" ]] && args+=(-m "$model")
[[ -n "$schema" ]] && args+=(--output-schema "$schema")
# the CLI's stdout is read by lib/limited.py --capture OUTSIDE the cell (the CLI never holds a descriptor on a harness file);
# once the CLI is gone the group is killed and the pipe gets ONE bounded grace: a process that escaped the group (setsid)
# and still holds the pipe cannot keep the adapter waiting; it leaves $sbxdir/orphan (row error orphan-process).
python3 -I -B "$here/../lib/limited.py" --capture "$raw" --orphan "$sbxdir/orphan" --stdin "$prompt" --stderr "$errf" 0 -- \
  python3 -I -B "$here/../lib/runenv.py" --cwd "$workdir" --home "$home" --gocache "$gc" --tmpdir "$celltmp" \
  --set "CODEX_HOME=$home" ${auth_pass[@]+"${auth_pass[@]}"} -- ${sb_exec[@]+"${sb_exec[@]}"} "$codex_bin" "${args[@]}" - 9>&- &
runpid=$!
wait "$runpid"; rc=$?; runpid=""
scrub_auth
if [[ -s "$errf" ]]; then tail -n 5 "$errf" | cut -c1-200 >&2; fi
pout="$(python3 -I -B "$here/../lib/parse_codex.py" "$raw" "$out" "$usage")"; prc=$?
if [[ $prc -ne 0 && $rc -eq 0 ]]; then rc=3; [[ "$pout" == stream-trailing-data ]] && rc=82; fi
if [[ -e "$sbxdir/orphan" ]]; then
  echo "codex.sh: ORPHAN PROCESS (error: orphan-process): a process of the cell outlived the CLI and still held its stdout; it may keep running, sandboxed but network-capable" >&2
  [[ $rc -eq 0 || $rc -eq 3 || $rc -eq 82 ]] && rc=81
fi
[[ $scrub_failed -eq 1 ]] && rc=80
exit "$rc"
