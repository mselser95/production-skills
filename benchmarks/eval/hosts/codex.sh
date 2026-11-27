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
#  - the copy is deleted after the CLI exits and on every exit path, TERM/INT/HUP included. Never printed.
# <budget-usd> is NOT enforced: codex has no spend cap; only timeout_s binds.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
workdir="$1" home="$2" prompt="$3" out="$4" usage="$5" model="${6:-}" _budget="${7:-1}" mode="${8:-read-only}" schema="${9:-}"
denyroots=""; if [[ "${10:-}" == --deny-roots ]]; then denyroots="${11:-}"; fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$mode" in read-only|workspace-write) ;; *) echo "codex.sh: unknown agent_mode '$mode'" >&2; exit 2 ;; esac

real="${EVAL_CODEX_REAL_HOME:-$HOME/.codex}"
copy="$home/auth.json" auth_pass=() child="" pipe="" sbxdir=""
scrub_auth() { { set +x; } 2>/dev/null; rm -f "$copy"; }   # the copy never outlives the CLI; nothing is ever copied back out
cleanup() {
  if [[ -n "$sbxdir" && -s "$sbxdir/pid" ]]; then child="$(cat "$sbxdir/pid")"; kill -TERM "$child" 2>/dev/null; fi
  if [[ -n "$pipe" ]]; then wait "$pipe" 2>/dev/null; pipe=""; fi
  scrub_auth; [[ -n "$sbxdir" ]] && rm -rf "$sbxdir"; return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # `wait` below (not a foreground child) lets the trap fire at once; the EXIT trap scrubs
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
elif [[ -e "$real/auth.json" || -L "$real/auth.json" ]]; then
  { set +x; } 2>/dev/null
  # O_NOFOLLOW + regular-file check + a NEW file (O_EXCL) at 0600; the content is never inspected or printed
  python3 -I -B -c 'import os,stat,sys
src,dst=sys.argv[1:3]
try:
    fd=os.open(src,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
except OSError as e:
    sys.exit("auth.json is a symlink or cannot be opened (%s): refused" % e.strerror)
st=os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_size>(1<<20):
    sys.exit("auth.json is not a small regular file: refused")
data=b""
while True:
    c=os.read(fd,65536)
    if not c: break
    data+=c
o=os.open(dst,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
os.fchmod(o,0o600); os.write(o,data); os.close(o)' "$real/auth.json" "$copy" || { scrub_auth; echo "codex.sh: cannot stage auth (credential)" >&2; exit 78; }
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
{ python3 -I -B "$here/../lib/runenv.py" --cwd "$workdir" --home "$home" --gocache "$gc" --tmpdir "$celltmp" \
  --set "CODEX_HOME=$home" ${auth_pass[@]+"${auth_pass[@]}"} -- ${sb_exec[@]+"${sb_exec[@]}"} "$codex_bin" "${args[@]}" - <"$prompt" 2>"$errf" &
echo $! >"$sbxdir/pid"; wait $!; echo $? >"$sbxdir/rc"; } | cat >"$raw" &   # stdout through a pipe read OUTSIDE the cell (/bin/cat cannot write a file fd under the profile: EPERM)
pipe=$!
wait "$pipe"; rc="$(cat "$sbxdir/rc" 2>/dev/null)"; rc="${rc:-1}"
scrub_auth
if [[ -s "$errf" ]]; then tail -n 5 "$errf" | cut -c1-200 >&2; fi
python3 -I -B "$here/../lib/parse_codex.py" "$raw" "$out" "$usage" || { [[ $rc -eq 0 ]] && rc=3; }
exit "$rc"
