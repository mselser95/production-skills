#!/usr/bin/env bash
# claude.sh -- Claude Code adapter. Contract:
#   <workdir> <host-home> <prompt-file> <output-file> <usage-json> <model> <budget-usd> <agent_mode> [<schema-file> [--deny-roots a:b]]
# (--deny-roots: the selftest only, replaces the seatbelt denied roots; run.sh never passes it)
# <schema-file> (9th, optional, "" = none) is corpus/<skill>/_lib/output.schema.json when the
# skill has one (run.sh decides). Present -> `--json-schema <the schema as ONE line of JSON>`
# (`claude --help`: "--json-schema <schema>  JSON Schema for structured output validation (only
# works with --print)", example given INLINE, so the file's content is passed, not its path).
# The structured result's field name in the `--output-format json` result is NOT in --help:
# lib/parse_claude.py accepts `structured_output` and falls back to `result`.
# Exit 78 = no credential (run.sh records error "auth" and stops a live loop).
#
# Isolation: the host runs under lib/runenv.py (no inherited environment, HOME
# and CLAUDE_CONFIG_DIR = the throwaway <host-home>, cwd = workdir), so none of
# the user's settings, hooks, plugins, skills or CLAUDE.md load. Auth order and
# credential hygiene: lib/auth.sh.
#
# Least privilege, two layers:
#  1. OS: the host runs under macOS seatbelt (`sandbox-exec -f <profile>`, profile
#     per cell from lib/seatbelt.py). Writes: denied except home, GOCACHE, per-cell TMPDIR and
#     -- only in workspace-write -- the workdir. This is the real control (tool-pattern prefixes
#     cannot stop `go test -exec`, `go build -o /x`, `git diff --output=`). Reads: Bash is
#     unrestricted and the network is open, so anything readable is exfiltratable; user data is
#     therefore DEFAULT-DENY (/Users /Volumes /tmp /var/folders, docker/agent sockets) and only
#     the cell's dirs, the workdir and the CLI/toolchain install roots are re-allowed. The profile
#     file sits in its own dir (sbx.XXXXXX) beside the home, which the agent cannot read.
#     No sandbox-exec, or a profile that cannot run -> exit 79 (row error "sandbox"); NEVER a
#     silent unconfined run. EVAL_CLAUDE_NO_SANDBOX=1 is the explicit, loud opt-out (row
#     sandbox:"off"). The denied roots can be replaced only by the selftest-only `--deny-roots` argument, never by environment.
#  2. Tools. Sandbox ON: `Read Glob Grep Bash` (read-only, dontAsk) / plus Edit Write
#     (workspace-write, acceptEdits), no Bash patterns, no escape-flag denies (dead rules once
#     the OS sandbox exists). Sandbox OFF (opt-out): the narrow allowlist (go version|build|vet|
#     test, git read; gofmt in workspace-write) plus the escape-flag denies -- there they are
#     the only confinement. WebFetch/WebSearch denied always; outbound network is NOT blocked.
#     CLAUDE_CODE_TMPDIR points claude's own shell scratch dir at the per-cell TMPDIR (found by
#     a paid probe: it otherwise writes /private/tmp/claude-<uid>, which the sandbox denies).
#     bypassPermissions is never used.
# `--setting-sources ""` is NOT passed: `claude --help` only documents a
# comma list of user|project|local, and the user source is the empty isolated home.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
workdir="$1" home="$2" prompt="$3" out="$4" usage="$5" model="${6:-}" budget="${7:-1}" mode="${8:-read-only}" schema="${9:-}"
denyroots=""; if [[ "${10:-}" == --deny-roots ]]; then denyroots="${11:-}"; fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/auth.sh
source "$here/../lib/auth.sh"

gocache="${EVAL_GOCACHE:-$home/gocache}"; celltmp="${EVAL_CELL_TMPDIR:-$home/tmp}"
case "$mode" in read-only|workspace-write) ;; *) echo "claude.sh: unknown agent_mode '$mode'" >&2; exit 2 ;; esac
sb_exec=() sandboxed=0 claude_bin=claude
if [[ "${EVAL_CLAUDE_NO_SANDBOX:-0}" == 1 || "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then
  echo "claude.sh: WARNING: EVAL_NO_SANDBOX=1 / EVAL_CLAUDE_NO_SANDBOX=1 -- the agent runs UNCONFINED (row sandbox:off); results are not comparable with sandboxed rows" >&2
else
  # seatbelt exists on macOS only; `uname` is resolved from PATH (tests put a fake first)
  if [[ "$(uname)" != Darwin ]]; then
    echo "claude.sh: no seatbelt sandbox on $(uname) -- refusing an unconfined run (error: sandbox). Live claude runs are macOS-only unless EVAL_CLAUDE_NO_SANDBOX=1." >&2; exit 79
  fi
  sbx="$(command -v sandbox-exec)" || { echo "claude.sh: sandbox-exec not found; refusing an unconfined run (error: sandbox). Set EVAL_CLAUDE_NO_SANDBOX=1 to opt out explicitly." >&2; exit 79; }
  # The profile names the cell's paths: it lives in its OWN dir next to the home (inside the cell's temp
  # root, under a denied root and never re-allowed), so the agent can neither read nor list it. Random
  # name, nothing of the task in it.
  sbxdir="$(mktemp -d "$(dirname "$home")/sbx.XXXXXX")" || { echo "claude.sh: cannot create the sandbox profile dir (error: sandbox)" >&2; exit 79; }
  trap 'rm -rf "$sbxdir"' EXIT
  profile="$sbxdir/p.sb"
  # realpath through every symlink (python3 is already a hard dependency)
  rp() { python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }
  repo_root="$(cd "$here/../../.." && pwd)"
  # user data is default-deny (lib/seatbelt.py); here only what the cell needs is re-allowed for READ:
  # the CLI's install root (the real file's dir: the PATH entry is usually a symlink into the user's
  # home), and the Go toolchain / git exec path (seatbelt.py emits those only if a denied root hides them).
  claude_bin=claude; sb_args=()
  if cl="$(command -v claude)" && [[ -n "$cl" ]]; then
    claude_bin="$(rp "$cl")"; sb_args+=(--allow-read "$(dirname "$claude_bin")")
  fi
  goroot="$(GOTOOLCHAIN=local go env GOROOT 2>/dev/null)" && [[ -n "$goroot" ]] && sb_args+=(--allow-read "$goroot")
  gx="$(git --exec-path 2>/dev/null)" && [[ -n "$gx" ]] && sb_args+=(--allow-read "$gx")
  # denied AGAIN after the re-allows: the repo (answer key, .git object store), real config/auth dirs
  sb_args+=(--deny-read "$repo_root" --protect "$sbxdir")
  # the task dir is only PROTECTED (no re-allow may cover it), never written into the profile: its path carries the task id
  [[ -n "${EVAL_TASK_DIR:-}" ]] && sb_args+=(--protect "$EVAL_TASK_DIR")
  [[ -n "${EVAL_CLAUDE_AUTH_DIR:-}" ]] && sb_args+=(--deny-read "$EVAL_CLAUDE_AUTH_DIR")
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && sb_args+=(--deny-read "$CLAUDE_CONFIG_DIR")
  # denied roots REPLACED by arguments 10-11 (`--deny-roots a:b`): only the selftest passes it, run.sh never does,
  # and no environment variable can (a caller's environment must not be able to weaken a live run). Data, never code.
  if [[ -n "$denyroots" ]]; then
    IFS=: read -r -a dr <<<"$denyroots"
    for r in "${dr[@]}"; do [[ -n "$r" ]] && sb_args+=(--deny-root "$r"); done
  fi
  python3 -I -B "$here/../lib/seatbelt.py" "$workdir" "$home" "$gocache" "$celltmp" "$mode" "${sb_args[@]}" >"$profile" || { echo "claude.sh: cannot build the sandbox profile (error: sandbox)" >&2; exit 79; }
  "$sbx" -f "$profile" /usr/bin/true >/dev/null 2>&1 || { echo "claude.sh: the sandbox profile does not run (error: sandbox)" >&2; exit 79; }
  sb_exec=("$sbx" -f "$profile"); sandboxed=1
fi

if ! eval_claude_auth; then echo "claude.sh: no usable credential (auth)" >&2; exit 78; fi

if [[ $sandboxed -eq 1 ]]; then
  # The OS sandbox confines writes and denies secret reads, so Bash is allowed WITHOUT a pattern list
  # (the model's natural `cat x && go test | tail` works; a prefix allowlist cannot stop `go test -exec`
  # anyway). Escape-flag deny patterns would be dead rules here and are not passed.
  case "$mode" in
    read-only) pm=dontAsk; allowed="Read Glob Grep Bash"; denied="Edit Write NotebookEdit WebFetch WebSearch" ;;
    workspace-write) pm=acceptEdits; allowed="Read Glob Grep Edit Write Bash"; denied="NotebookEdit WebFetch WebSearch" ;;
  esac
else
  # No OS sandbox (explicit opt-out): the narrow allowlist is the ONLY confinement.
  bash_allow="Bash(go version:*) Bash(go build:*) Bash(go vet:*) Bash(go test:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*)"
  # Escape flags, in the wildcard form `claude --help` documents (`Bash(git *)`); whether a pattern
  # with the wildcard BEFORE the flag matches is unconfirmed without a paid denial test.
  escape_deny='Bash(go test *-exec*) Bash(go test *-toolexec*) Bash(go build *-o*) Bash(go vet *-vettool*) Bash(git diff *--output*) Bash(git -c *) Bash(git --exec-path*)'
  case "$mode" in
    read-only) pm=dontAsk; allowed="Read Glob Grep $bash_allow"; denied="Edit Write NotebookEdit WebFetch WebSearch $escape_deny" ;;
    workspace-write) pm=acceptEdits; allowed="Read Glob Grep Edit Write $bash_allow Bash(gofmt:*)"; denied="NotebookEdit WebFetch WebSearch $escape_deny" ;;
  esac
fi

raw="$home/.eval-claude.json"
args=(-p --output-format json --permission-mode "$pm" --allowedTools "$allowed" --disallowedTools "$denied"
      --no-session-persistence --strict-mcp-config --max-budget-usd "$budget")
[[ -n "$model" ]] && args+=(--model "$model")
if [[ -n "$schema" ]]; then
  schema_json="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' "$schema")" \
    && [[ -n "$schema_json" ]] || { echo "claude.sh: cannot read the output schema $schema" >&2; exit 2; }
  args+=(--json-schema "$schema_json")
fi
python3 -I -B "$here/../lib/runenv.py" --cwd "$workdir" --home "$home" --gocache "$gocache" --tmpdir "$celltmp" \
  --set "CLAUDE_CONFIG_DIR=$home" --set "CLAUDE_CODE_TMPDIR=$celltmp" --pass "$EVAL_AUTH_VAR" -- ${sb_exec[@]+"${sb_exec[@]}"} "$claude_bin" "${args[@]}" <"$prompt" >"$raw" 2>"$home/.eval-claude.err"
rc=$?
if [[ -s "$home/.eval-claude.err" ]]; then tail -n 5 "$home/.eval-claude.err" | cut -c1-200 >&2; fi
python3 -I -B "$here/../lib/parse_claude.py" "$raw" "$out" "$usage"
prc=$?
if [[ $rc -eq 0 && $prc -ne 0 ]]; then rc=$prc; fi
exit "$rc"
