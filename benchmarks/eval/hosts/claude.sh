#!/usr/bin/env bash
# claude.sh -- Claude Code adapter. Contract:
#   <workdir> <host-home> <prompt-file> <output-file> <usage-json> <model> <budget-usd> <agent_mode> [<schema-file>]
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
#     per cell from lib/seatbelt.py): every file write is denied except home,
#     GOCACHE, per-cell TMPDIR and -- only in workspace-write -- the workdir. This
#     is the real control (tool-pattern prefixes cannot stop `go test -exec`,
#     `go build -o /x`, `git diff --output=`). No sandbox-exec, or a profile that
#     cannot run -> exit 79 (row error "sandbox"); NEVER a silent unconfined run.
#     EVAL_CLAUDE_NO_SANDBOX=1 is the explicit, loud opt-out (row sandbox:"off").
#     The profile also DENIES READS of the caller's secrets (ssh, aws, gnupg, gh, gcloud,
#     netrc, npmrc, docker, kube, real ~/.claude* and ~/.codex, Library/Keychains) and of the
#     answer key (<repo>/benchmarks/eval/corpus, the task dir): Bash is unrestricted and the
#     network is open, so anything readable is exfiltratable.
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
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/auth.sh
source "$here/../lib/auth.sh"

gocache="${EVAL_GOCACHE:-$home/gocache}"; celltmp="${EVAL_CELL_TMPDIR:-$home/tmp}"
case "$mode" in read-only|workspace-write) ;; *) echo "claude.sh: unknown agent_mode '$mode'" >&2; exit 2 ;; esac
sb_exec=() sandboxed=0
if [[ "${EVAL_CLAUDE_NO_SANDBOX:-0}" == 1 ]]; then
  echo "claude.sh: WARNING: EVAL_CLAUDE_NO_SANDBOX=1 -- the agent runs UNCONFINED (row sandbox:off); results are not comparable with sandboxed rows" >&2
else
  # seatbelt exists on macOS only; `uname` is resolved from PATH (tests put a fake first)
  if [[ "$(uname)" != Darwin ]]; then
    echo "claude.sh: no seatbelt sandbox on $(uname) -- refusing an unconfined run (error: sandbox). Live claude runs are macOS-only unless EVAL_CLAUDE_NO_SANDBOX=1." >&2; exit 79
  fi
  sbx="$(command -v sandbox-exec)" || { echo "claude.sh: sandbox-exec not found; refusing an unconfined run (error: sandbox). Set EVAL_CLAUDE_NO_SANDBOX=1 to opt out explicitly." >&2; exit 79; }
  profile="$home/.eval-seatbelt.sb"
  # read-deny: the caller's real secrets, the repo's answer key (corpus + this task). Real config dirs
  # named by env are denied too. HOME here is the CALLER's (the isolated HOME is set later, by runenv).
  sb_args=(--real-home "$HOME" --repo "$(cd "$here/../../.." && pwd)")
  [[ -n "${EVAL_TASK_DIR:-}" ]] && sb_args+=(--task-dir "$EVAL_TASK_DIR")
  [[ -n "${EVAL_CLAUDE_AUTH_DIR:-}" ]] && sb_args+=(--deny-read "$EVAL_CLAUDE_AUTH_DIR")
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && sb_args+=(--deny-read "$CLAUDE_CONFIG_DIR")
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
  --set "CLAUDE_CONFIG_DIR=$home" --set "CLAUDE_CODE_TMPDIR=$celltmp" --pass "$EVAL_AUTH_VAR" -- ${sb_exec[@]+"${sb_exec[@]}"} claude "${args[@]}" <"$prompt" >"$raw" 2>"$home/.eval-claude.err"
rc=$?
if [[ -s "$home/.eval-claude.err" ]]; then tail -n 5 "$home/.eval-claude.err" | cut -c1-200 >&2; fi
python3 -I -B "$here/../lib/parse_claude.py" "$raw" "$out" "$usage"
prc=$?
if [[ $rc -eq 0 && $prc -ne 0 ]]; then rc=$prc; fi
exit "$rc"
