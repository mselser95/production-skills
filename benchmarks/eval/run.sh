#!/usr/bin/env bash
# run.sh -- run ONE corpus cell and append ONE row to a results JSONL.
#
# WHY THIS EXISTS. "Does the skill make the agent better than the same agent
# without it?" is only answerable if the two arms differ in exactly one thing.
# So: same fixture, same prompt (bar one appended sentence), same model, an
# ISOLATED host home (the user's real ~/.claude* / ~/.codex carry unrelated
# skills and instructions that would contaminate both arms), and a grader the
# agent can never see. A cell that fails to start, times out or gets a grader
# error still writes a row (pass:false + error): a missing row would inflate
# the success rate.
#
# Row also carries kind and language (task.json) and output_valid (null without a schema, else: did the agent's
#   output parse as a JSON object).
# Usage: run.sh --task <task-dir> --arm skill|bare --host claude|codex|stub
#               --rep N --out <results.jsonl> [--model M]
# Env:   EVAL_KEEP=1          keep the temp dirs (printed to stderr)
#        EVAL_SKILLS_ROOT     where <skill>/ dirs live (default: repo root)
#        EVAL_REPO_ROOT       repo whose git history yields skill_sha/harness_sha (tests)
#        EVAL_SKIP_GRADER=1  run the host WITHOUT grading (row error "grader-skipped", pass:false): for tests of the host
#                            wiring only; live.sh refuses to run with it set
#        EVAL_SWEEP_MINUTES  age (>= 30, default 180) after which a stale eval-cell.* dir of ours is swept at start
#        --preflight         validate and decide, run nothing: exit 0 the cell can be graded here | 5 it cannot (reason on stderr)
# THE GRADER ONLY EVER READS A WORKDIR THE AGENT COULD NOT WRITE. The grader runs outside any sandbox, so an agent-written
# tree (a `.git/config` with core.fsmonitor, a test file) would execute with the user's privileges. grade_ok() below is the one
# predicate, used BEFORE the host starts (no paid call is spent on a cell that cannot be graded) and again after it:
#   sandbox seatbelt + agent_mode read-only -> graded | host stub (no agent) -> graded | anything else -> "grader-unconfined"
# On top of that: the workdir's git metadata is digested before the CLI starts and compared after it ("workdir-tampered",
# no grading) and the grader's git runs neutralised (GIT_CONFIG_NOSYSTEM/GLOBAL, env-injected core.* overrides).
# The grader itself is NOT run under a sandbox (next task).
# Exit:  0 a row was written | 2 bad usage / task unreadable (no row possible)
#        3 a row was written but the cell cannot run on this machine (error "auth" or "sandbox"): a live loop must STOP
#        4 a row was written but a credential copy (or the cell) could not be removed (error "scrub-failed: <path>"): STOP
#        5 --preflight only: the cell would be refused
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${EVAL_REPO_ROOT:-$(cd "$here/../.." && pwd)}"
# shellcheck source=lib/workdir.sh
source "$here/lib/workdir.sh"
skills_root="${EVAL_SKILLS_ROOT:-$repo}"

task="" arm="" host="" rep="" out="" model="" order_seed="" preflight=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --arm) arm="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    --rep) rep="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --order-seed) order_seed="${2:-}"; shift 2 ;;
    --preflight) preflight=1; shift ;;
    *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
die() { echo "run.sh: $*" >&2; exit 2; }
[[ -d "$task" && -f "$task/task.json" ]] || die "--task must be a task dir with task.json"
[[ "$arm" == skill || "$arm" == bare ]] || die "--arm must be skill|bare"
[[ -f "$here/hosts/$host.sh" ]] || die "--host must be one of: $(cd "$here/hosts" && ls ./*.sh | sed 's|./||; s|\.sh||' | tr '\n' ' ')"
[[ "$rep" =~ ^[0-9]+$ ]] || die "--rep must be an integer"
[[ -n "$out" || $preflight -eq 1 ]] || die "--out is required"
task="$(cd "$task" && pwd)"
export EVAL_TASK_DIR="$task"   # read by the claude adapter: the seatbelt profile denies reads of it
if [[ $preflight -eq 0 ]]; then case "$out" in /*) ;; *) out="$PWD/$out" ;; esac; mkdir -p "$(dirname "$out")"; fi

jget() { python3 -I -B "$here/lib/jget.py" "$task/task.json" "$1"; }
skill="$(jget skill)" || die "task.json has no skill"
task_id="$(jget id)" || die "task.json has no id"
prompt_text="$(jget prompt)" || die "task.json has no prompt"
timeout_s="$(jget timeout_s)" || die "task.json has no timeout_s"
budget="$(jget max_budget_usd)" || die "task.json has no max_budget_usd"
agent_mode="$(jget agent_mode)" || die "task.json has no agent_mode"
jget kind >/dev/null || die "task.json has no kind"   # required; the row copies it from task.json
jget language >/dev/null || die "task.json has no language"   # required; the row copies it from task.json
[[ "$agent_mode" == read-only || "$agent_mode" == workspace-write ]] || die "agent_mode must be read-only|workspace-write"

# the skill's output schema, when it has one: corpus/<skill>/_lib/output.schema.json beside the task dirs.
# Present -> every host adapter gets it as its 9th argument and must make the agent answer under it.
schema=""; schema_applies=0
if [[ -f "$(dirname "$task")/_lib/output.schema.json" ]]; then schema="$(dirname "$task")/_lib/output.schema.json"; schema_applies=1; fi

# which confinement this row ran under; a report never pools different values
case "$host" in
  claude) sandbox=seatbelt
          if [[ "${EVAL_CLAUDE_NO_SANDBOX:-0}" == 1 || "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then sandbox=off; echo "run.sh: WARNING: EVAL_NO_SANDBOX=1 / EVAL_CLAUDE_NO_SANDBOX=1, this claude cell runs UNCONFINED (sandbox:off)" >&2; fi ;;
  codex) sandbox=seatbelt
         if [[ "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then sandbox=codex; echo "run.sh: WARNING: EVAL_NO_SANDBOX=1, this codex cell runs under Codex's OWN sandbox: reads are unconfined (sandbox:codex)" >&2; fi ;;
  *) sandbox="n/a" ;;
esac

# the grader only ever reads a workdir the agent could not write (see the header)
grade_ok() {
  [[ "$agent_mode" == read-only ]] || return 1       # a workspace-write agent writes the workdir, whatever confines it
  case "$sandbox" in
    n/a) return 0 ;;                                 # the stub host: harness code, no agent
    seatbelt) return 0 ;;                            # the profile denies every write to the workdir in read-only mode
    *) return 1 ;;                                   # sandbox off / codex' own sandbox: workspace-write in EVERY mode
  esac
}
grade_refusal() { echo "run.sh: refusing to run the grader of $task_id (sandbox $sandbox, agent_mode $agent_mode): the agent could write the workdir, so the grader would execute agent-written files unconfined (error: grader-unconfined)" >&2; }
if [[ $preflight -eq 1 ]]; then
  if grade_ok; then exit 0; fi
  grade_refusal; exit 5
fi
refused=0
if ! grade_ok && [[ "${EVAL_SKIP_GRADER:-0}" != 1 ]]; then refused=1; grade_refusal; fi
# ---- cell hygiene ------------------------------------------------------------------------------------------------------
# eval_remove_tree <dir> -> 0 gone | 1 remains. The agent writes the cell dirs, so it may have made them undeletable (chmod 000 /
# 500 on a directory, chflags uchg): permissions and immutable flags are reset FROM OUTSIDE first (lib/scrub.py reset: no symlink
# is ever followed), then removed; one retry; the caller VERIFIES by this return value, never by the exit status of rm.
eval_remove_tree() {
  local d="$1"
  for _try in 1 2; do
    [[ -e "$d" || -L "$d" ]] || return 0
    python3 -I -B "$here/lib/scrub.py" reset "$d"
    rm -rf "$d" 2>/dev/null
  done
  [[ ! -e "$d" && ! -L "$d" ]]
}
# STARTUP SWEEP: a SIGKILLed run leaves its 0700 cell (and in the worst case a 0600 credential copy) behind. Every start removes
# the stale eval-cell.* dirs it OWNS under its temp root (older than EVAL_SWEEP_MINUTES, >= 30; real directories only, never a
# symlink; a dir holding .eval-keep is left alone; any other name or owner is never touched) with the same reset-then-remove.
sweep_stale() {
  local min="${EVAL_SWEEP_MINUTES:-180}" d
  [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 30 )) || min=180
  while IFS= read -r -d '' d; do
    if eval_remove_tree "$d"; then echo "run.sh: startup sweep removed stale cell $d (older than $min min)" >&2
    else echo "run.sh: startup sweep could NOT remove stale cell $d: it may still hold a credential copy; remove it by hand" >&2; fi
  done < <(python3 -I -B "$here/lib/scrub.py" stale "${TMPDIR:-/tmp}" eval-cell. "$min")
}
sweep_stale
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-cell.XXXXXX")" || die "mktemp failed"
child=""
scrub_fail=""
# scrub_cell: the agent-reachable part of the cell (home gocache celltmp work + the adapter's sbx.* dir) is removed with a
# permission/flag reset, EVAL_KEEP or not for the credential files; on failure scrub_fail names the first path that remains.
scrub_cell() {
  local d f
  if [[ "${EVAL_KEEP:-0}" == 1 ]]; then
    python3 -I -B "$here/lib/scrub.py" reset "$tmp/home"
    for f in "$tmp/home/auth.json" "$tmp/home/.credentials.json"; do
      rm -f "$f" 2>/dev/null
      if [[ -e "$f" || -L "$f" ]]; then scrub_fail="${scrub_fail:-$f}"; fi
    done
  else
    for d in "$tmp/home" "$tmp/gocache" "$tmp/celltmp" "$tmp/work" "$tmp"/sbx.*; do
      eval_remove_tree "$d" || scrub_fail="${scrub_fail:-$d}"
    done
  fi
  if [[ -n "$scrub_fail" ]]; then echo "run.sh: SCRUB FAILED: $scrub_fail is still on disk and may hold a copy of the credential; remove $tmp by hand (error: scrub-failed)" >&2; fi
}
cleanup() {
  [[ -n "$scrub_fail" ]] || scrub_cell   # the normal path already ran it before the row was written (idempotent)
  if [[ "${EVAL_KEEP:-0}" == 1 ]]; then echo "run.sh: kept $tmp" >&2
  elif ! eval_remove_tree "$tmp"; then echo "run.sh: SCRUB FAILED: $tmp could not be removed and may hold a credential copy (error: scrub-failed)" >&2; exit 4; fi
}
trap cleanup EXIT
# TERM/INT/HUP: take the child (limited.py -> host process group) down FIRST,
# then exit so the EXIT trap removes the temp dirs. `wait` lets the trap fire now.
onsig() {
  if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  exit 143
}
trap onsig TERM INT HUP
if [[ "${EVAL_KEEP:-0}" == 1 ]]; then : >"$tmp/.eval-keep"; fi   # the startup sweep leaves a kept cell alone
workdir="$tmp/work" home="$tmp/home" promptf="$tmp/prompt.txt"
outf="$tmp/agent-output.txt" usagef="$tmp/usage.json" hostlog="$tmp/host.log"
gradeo="$tmp/grade.out" gradee="$tmp/grade.err"
export EVAL_GOCACHE="$tmp/gocache"   # per cell, outside the workdir
export EVAL_CELL_TMPDIR="$tmp/celltmp"   # the one temp dir the agent may write
mkdir -p "$home" "$EVAL_GOCACHE" "$EVAL_CELL_TMPDIR"
: >"$outf"

# <short sha> clean at HEAD | <short sha>+dirty (path differs from HEAD) | unknown (never committed)
sha_of() {
  local s st
  s="$(cd "$repo" && git log -1 --format=%h -- "$1" 2>/dev/null)"
  [[ -n "$s" ]] || { echo unknown; return; }
  st="$(cd "$repo" && git status --porcelain -- "$1" 2>/dev/null)"
  if [[ -n "$st" ]]; then echo "$s+dirty"; else echo "$s"; fi
}
skill_sha="$(sha_of "$skill")"
harness_sha="$(sha_of benchmarks/eval)"
now() { python3 -I -B -c 'import time;print(time.time())'; }

err="" host_rc=-1 timed_out=0 grade_rc=-1 can_grade=0 auth_fail=0 t0="$(now)"

digest0="" digest1=""
if [[ $refused -eq 1 ]]; then
  err="grader-unconfined"   # refused BEFORE the host starts: no (paid) call is made for a cell that cannot be graded
elif ! eval_mkworkdir "$task" "$workdir"; then
  err="fixture or fixture.setup.sh failed"
else
  # the isolated home; the skill arm installs the skill, dereferenced
  # (skill references/ are symlinks into _shared/ and would dangle otherwise)
  printf '%s\n' "$prompt_text" >"$promptf"
  if [[ "$arm" == skill ]]; then
    if [[ -f "$skills_root/$skill/SKILL.md" ]]; then
      mkdir -p "$home/skills"
      cp -RL "$skills_root/$skill" "$home/skills/$skill" || err="cannot install skill"
      printf '\nUse the %s skill for this.\n' "$skill" >>"$promptf"
    else
      err="skill dir $skill/SKILL.md not found under $skills_root"
    fi
  fi
  if [[ -z "$err" ]]; then
    # git metadata the harness created, digested BEFORE the CLI starts (never after: that would bless the agent's edits)
    digest0="$(python3 -I -B "$here/lib/scrub.py" gitdigest "$workdir" 2>/dev/null)"
    python3 -I -B "$here/lib/limited.py" "$timeout_s" -- \
      bash "$here/hosts/$host.sh" "$workdir" "$home" "$promptf" "$outf" "$usagef" "$model" "$budget" "$agent_mode" "$schema" \
      >"$hostlog" 2>&1 &
    child=$!; wait "$child"; host_rc=$?; child=""
    can_grade=1   # whatever state the host left is graded; row.py still refuses a pass after a crash/timeout
    if [[ $host_rc -eq 124 ]]; then timed_out=1; fi
    if [[ $host_rc -eq 78 ]]; then
      err="auth"; auth_fail=1; can_grade=0
    elif [[ $host_rc -eq 79 ]]; then
      err="sandbox"; auth_fail=1; can_grade=0
    elif [[ $host_rc -eq 81 ]]; then
      err="orphan-process"
    elif [[ $host_rc -eq 82 ]]; then
      err="stream-trailing-data"
    elif [[ $host_rc -ne 0 && $timed_out -eq 0 && -s "$hostlog" ]]; then
      err="host exit $host_rc: $(tail -n 3 "$hostlog" | tr '\n"\\' '   ' | cut -c1-200)"
    fi
  fi
fi
t1="$(now)"

# the grader runs OUTSIDE the agent's view: cwd is the temp root, not the workdir
if [[ $can_grade -eq 1 ]]; then
  digest1="$(python3 -I -B "$here/lib/scrub.py" gitdigest "$workdir" 2>/dev/null)"
  if [[ -z "$digest0" || "$digest0" != "$digest1" ]]; then
    # the workdir's git config / hooks / attributes differ from what the harness created: an executing key may have been planted
    can_grade=0; err="workdir-tampered"
    echo "run.sh: refusing to run the grader of $task_id: the workdir's git metadata changed while the CLI ran (error: workdir-tampered)" >&2
  elif [[ "${EVAL_SKIP_GRADER:-0}" == 1 ]]; then
    can_grade=0; err="${err:-grader-skipped}"
  elif ! grade_ok; then   # defence in depth: refused before the host too
    can_grade=0; err="grader-unconfined"; grade_refusal
  fi
fi
if [[ $can_grade -eq 1 ]]; then
  # git neutralised for the grader: no system/global config, executing keys overridden through the environment (command-line
  # scope beats the repo-local config). The repo-local keys not listed here are covered by the digest above, not by this list.
  gitenv=(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=8
    GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null
    GIT_CONFIG_KEY_2=core.sshCommand GIT_CONFIG_VALUE_2=false
    GIT_CONFIG_KEY_3=core.pager GIT_CONFIG_VALUE_3=cat
    GIT_CONFIG_KEY_4=core.editor GIT_CONFIG_VALUE_4=true
    GIT_CONFIG_KEY_5=core.attributesFile GIT_CONFIG_VALUE_5=/dev/null
    GIT_CONFIG_KEY_6=credential.helper GIT_CONFIG_VALUE_6=
    GIT_CONFIG_KEY_7=protocol.ext.allow GIT_CONFIG_VALUE_7=never
    GIT_EXTERNAL_DIFF=true GIT_PAGER=cat GIT_EDITOR=true GIT_TERMINAL_PROMPT=0)
  (cd "$tmp" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_EXEC_PATH -u GIT_CONFIG_PARAMETERS -u GIT_INDEX_FILE "${gitenv[@]}" \
    python3 -I -B "$here/lib/limited.py" 120 -- bash "$task/grade.sh" "$workdir" "$outf") >"$gradeo" 2>"$gradee" &
  child=$!; wait "$child"; grade_rc=$?; child=""
fi

# the cell is removed BEFORE the row so a removal that fails is IN the row; the harness files (output, usage, grade) stay until exit
scrub_cell
if [[ -n "$scrub_fail" ]]; then err="scrub-failed: $scrub_fail"; fi

dur="$(python3 -I -B -c "print($t1 - $t0)")"
python3 -I -B "$here/lib/row.py" --task-json "$task/task.json" --task-id "$task_id" --skill "$skill" \
  --arm "$arm" --host "$host" --model "$model" --rep "$rep" --exit "$host_rc" \
  --grade-exit "$grade_rc" --timed-out "$timed_out" --duration "$dur" \
  --usage-file "$usagef" --grade-file "$gradeo" --sandbox "$sandbox" --order-seed "$order_seed" --skill-sha "$skill_sha" \
  --harness-sha "$harness_sha" --output-file "$outf" --schema "$schema_applies" --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --error="$err" --out "$out" || { echo "run.sh: could not write the row" >&2; exit 1; }
[[ -z "$scrub_fail" ]] || exit 4
[[ $auth_fail -eq 0 ]] || exit 3
