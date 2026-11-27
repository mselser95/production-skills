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
# Exit:  0 a row was written | 2 bad usage / task unreadable (no row possible)
#        a workspace-write task: the grader is REFUSED (row error "grader-unconfined", pass:false, exit 0)
#        3 a row was written but the cell cannot run on this machine (error "auth" or "sandbox"): a live loop must STOP
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${EVAL_REPO_ROOT:-$(cd "$here/../.." && pwd)}"
# shellcheck source=lib/workdir.sh
source "$here/lib/workdir.sh"
skills_root="${EVAL_SKILLS_ROOT:-$repo}"

task="" arm="" host="" rep="" out="" model="" order_seed=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --arm) arm="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    --rep) rep="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --order-seed) order_seed="${2:-}"; shift 2 ;;
    *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
die() { echo "run.sh: $*" >&2; exit 2; }
[[ -d "$task" && -f "$task/task.json" ]] || die "--task must be a task dir with task.json"
[[ "$arm" == skill || "$arm" == bare ]] || die "--arm must be skill|bare"
[[ -f "$here/hosts/$host.sh" ]] || die "--host must be one of: $(cd "$here/hosts" && ls ./*.sh | sed 's|./||; s|\.sh||' | tr '\n' ' ')"
[[ "$rep" =~ ^[0-9]+$ ]] || die "--rep must be an integer"
[[ -n "$out" ]] || die "--out is required"
task="$(cd "$task" && pwd)"
export EVAL_TASK_DIR="$task"   # read by the claude adapter: the seatbelt profile denies reads of it
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
mkdir -p "$(dirname "$out")"

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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-cell.XXXXXX")" || die "mktemp failed"
child=""
cleanup() {
  # a credential copy never outlives the cell, EVAL_KEEP or not
  rm -f "$tmp/home/auth.json" "$tmp/home/.credentials.json" 2>/dev/null
  if [[ "${EVAL_KEEP:-0}" == 1 ]]; then echo "run.sh: kept $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT
# TERM/INT/HUP: take the child (limited.py -> host process group) down FIRST,
# then exit so the EXIT trap removes the temp dirs. `wait` lets the trap fire now.
onsig() {
  if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  exit 143
}
trap onsig TERM INT HUP
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

# which confinement this row ran under; a report never pools different values
case "$host" in
  claude) sandbox=seatbelt
          if [[ "${EVAL_CLAUDE_NO_SANDBOX:-0}" == 1 || "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then sandbox=off; echo "run.sh: WARNING: EVAL_NO_SANDBOX=1 / EVAL_CLAUDE_NO_SANDBOX=1, this claude cell runs UNCONFINED (sandbox:off)" >&2; fi ;;
  codex) sandbox=seatbelt
         if [[ "${EVAL_NO_SANDBOX:-0}" == 1 ]]; then sandbox=codex; echo "run.sh: WARNING: EVAL_NO_SANDBOX=1, this codex cell runs under Codex's OWN sandbox: reads are unconfined (sandbox:codex)" >&2; fi ;;
  *) sandbox="n/a" ;;
esac
err="" host_rc=-1 timed_out=0 grade_rc=-1 can_grade=0 auth_fail=0 t0="$(now)"

if ! eval_mkworkdir "$task" "$workdir"; then
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
    elif [[ $host_rc -ne 0 && $timed_out -eq 0 && -s "$hostlog" ]]; then
      err="host exit $host_rc: $(tail -n 3 "$hostlog" | tr '\n"\\' '   ' | cut -c1-200)"
    fi
  fi
fi
t1="$(now)"

# the grader runs OUTSIDE the agent's view: cwd is the temp root, not the workdir
if [[ $can_grade -eq 1 && "$agent_mode" == workspace-write ]]; then
  # The grader runs OUTSIDE any sandbox, on the workdir. A workspace-write agent writes that tree: a grader that builds
  # or tests it (`go test`) would execute agent-written code unconfined, with the user's privileges. REFUSED (the
  # sandboxed grader is a later task); the host has already run, so this belongs in a loop's pre-flight, not here.
  can_grade=0; err="grader-unconfined"
  echo "run.sh: refusing to run the grader of $task_id (agent_mode workspace-write): it would execute agent-written files unconfined (error: grader-unconfined)" >&2
fi
if [[ $can_grade -eq 1 ]]; then
  (cd "$tmp" && python3 -I -B "$here/lib/limited.py" 120 -- bash "$task/grade.sh" "$workdir" "$outf") >"$gradeo" 2>"$gradee" &
  child=$!; wait "$child"; grade_rc=$?; child=""
fi

dur="$(python3 -I -B -c "print($t1 - $t0)")"
python3 -I -B "$here/lib/row.py" --task-json "$task/task.json" --task-id "$task_id" --skill "$skill" \
  --arm "$arm" --host "$host" --model "$model" --rep "$rep" --exit "$host_rc" \
  --grade-exit "$grade_rc" --timed-out "$timed_out" --duration "$dur" \
  --usage-file "$usagef" --grade-file "$gradeo" --sandbox "$sandbox" --order-seed "$order_seed" --skill-sha "$skill_sha" \
  --harness-sha "$harness_sha" --output-file "$outf" --schema "$schema_applies" --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --error="$err" --out "$out" || { echo "run.sh: could not write the row" >&2; exit 1; }
[[ $auth_fail -eq 0 ]] || exit 3
