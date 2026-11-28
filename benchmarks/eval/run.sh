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
# Env:   EVAL_KEEP=1          keep the cell's `work` and the harness's own captures/logs (printed to stderr). The agent-writable
#                             areas (home, gocache, celltmp, sbx.*) are removed as in any run, and `work` is scanned first: a file
#                             holding the staged credential (raw, base64, url-safe base64, hex) is DELETED (lib/redact.py)
#        EVAL_SKILLS_ROOT     where <skill>/ dirs live (default: repo root)
#        EVAL_REPO_ROOT       repo whose git history yields skill_sha/harness_sha (tests)
#        EVAL_SKIP_GRADER=1  run the host WITHOUT grading (row error "grader-skipped", pass:false): for tests of the host
#                            wiring only; live.sh refuses to run with it set
#        EVAL_SWEEP_MINUTES  age (>= 30, default 180) after which a stale eval-cell.* dir of ours is swept at start, unless its .eval-live
#                            marker names a live pid with its own start time (a cell older than the floor cannot exist: see timeout_s below)
#        --preflight         validate and decide, run nothing: exit 0 the cell can be graded here | 5 it cannot (reason on stderr)
# THE GRADER ONLY EVER READS A WORKDIR THE AGENT COULD NOT WRITE. The grader runs outside any sandbox, so an agent-written
# tree (a `.git/config` with core.fsmonitor, a test file) would execute with the user's privileges. grade_ok() below is the one
# predicate, used BEFORE the host starts (no paid call is spent on a cell that cannot be graded) and again after it:
#   sandbox seatbelt + agent_mode read-only -> graded | host stub (no agent) -> graded | anything else -> "grader-unconfined"
# On top of that: the workdir's git metadata is digested before the CLI starts and compared after it ("workdir-tampered",
# no grading) and the grader's git runs neutralised (GIT_CONFIG_NOSYSTEM/GLOBAL, env-injected core.* overrides).
# The grader itself is NOT run under a sandbox (next task).
# Exit:  0 a row was written | 2 bad usage / unknown --host (explicit list) / task unreadable / timeout_s out of bounds (no row possible)
#          143 TERM/INT, 129 HUP while the cell ran (the host's process group is killed, the cell removed, no row)
#        3 a row was written but the cell cannot run on this machine (error "auth" or "sandbox"): a live loop must STOP
#        4 a row was written but a credential copy (or the cell) could not be removed (error "scrub-failed: <path>"), or the staged
#          credential was FOUND in something the harness keeps (error "credential-in-output" / "credential-in-kept-files: <n>
#          file(s)", or "credential-scan-failed" when the scan itself could not run): STOP. lib/live.sh stops the live run on 4.
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
# HOSTS ARE AN EXPLICIT LIST, never a lookup of whatever file the name happens to reach (`--host ../lib/live` is a path; `CODEX` is
# hosts/codex.sh on a case-insensitive filesystem): the shape is checked first, then membership. Nothing has run or been created yet.
HOSTS="stub codex claude"
[[ "$host" =~ ^[a-z][a-z0-9-]*$ ]] && [[ " $HOSTS " == *" $host "* ]] || die "--host must be one of: $HOSTS"
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

# CELL LIFETIME vs THE STARTUP SWEEP. The sweep removes eval-cell.* dirs older than EVAL_SWEEP_MINUTES (default 180, FLOOR 30). That is
# safe only while no live cell can be older than the floor, so a task whose longest possible cell would reach it is refused here (a
# marker, .eval-live, protects a cell whose run.sh is alive: below; this bound is the second line, for a marker that cannot be trusted).
# Longest possible cell, in seconds, from the constants of the code (every term an UPPER bound, none a measurement):
#   setup      60   fixture copy, git init + commit, skill install (run.sh)
#   host     T+3    timeout_s T, then lib/limited.py kill_group: TERM, up to 2.0 s grace, KILL, up to 0.5 s (+0.5 s slack); the adapter
#                   is inside that group, its own scrub runs while the grace lasts and run.sh removes whatever the kill cut short
#   digests  20     two lib/scrub.py gitdigest walks of the workdir (10 each)
#   grader  123     lib/limited.py 120 s limit + the same 3 s kill allowance
#   tail    120     credential scan/redaction of the captures, scrub_cell, the row, the final removal
#   => T + 60 + 3 + 20 + 123 + 120 = T + 326, rounded UP to T + 330.
# Bound: strictly less than the sweep floor (30 min = 1800 s) minus a 5 min margin (300 s) = 1500 s  =>  T < 1170, so the largest
# accepted timeout_s is 1169 s. timeout_s must be > 0: limited.py reads 0 as "no limit", which no cell may have.
CELL_OVERHEAD_S=330 SWEEP_FLOOR_S=1800 SWEEP_MARGIN_S=300
awk -v t="$timeout_s" -v o="$CELL_OVERHEAD_S" -v b="$((SWEEP_FLOOR_S - SWEEP_MARGIN_S))" \
  'BEGIN{ok=(t ~ /^[0-9]+([.][0-9]+)?$/); exit !(ok && t+0 > 0 && t+o < b)}' \
  || die "timeout_s '$timeout_s' of $task_id must be a number > 0 and < $((SWEEP_FLOOR_S - SWEEP_MARGIN_S - CELL_OVERHEAD_S)) (a cell may live at most $((SWEEP_FLOOR_S - SWEEP_MARGIN_S)) s, under the sweep floor of $SWEEP_FLOOR_S s)"

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
  stub) sandbox="n/a" ;;
  *) die "--host must be one of: $HOSTS" ;;
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
# The agent writes the cell's children (home gocache celltmp work), so it can replace any of them by a symlink, chmod 000 a
# directory or chflags uchg a file. NOTHING here removes or chmods by a path the agent could have replaced: every removal is
# lib/scrub.py rmcell / rmname, which walk by directory descriptor (O_NOFOLLOW, no symlink ever followed; see scrub.py).
# STARTUP SWEEP: a SIGKILLed run leaves its 0700 cell (and in the worst case a 0600 credential copy) behind. Every start removes
# the stale eval-cell.* dirs it OWNS under its temp root (older than EVAL_SWEEP_MINUTES, >= 30; real directories only, never a
# symlink; a dir holding .eval-keep is left alone; any other name or owner is never touched) with the same routine. It does
# nothing when TMPDIR is unset/empty, a shared temp root (/, /tmp, /private/tmp, /var/tmp) or not ours (scrub.py sweepok).
sweep_stale() {
  local min="${EVAL_SWEEP_MINUTES:-180}" d why
  [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 30 )) || min=180
  if ! why="$(python3 -I -B "$here/lib/scrub.py" sweepok "${TMPDIR:-}" 2>&1)"; then
    echo "run.sh: startup sweep skipped: $why" >&2; return 0
  fi
  while IFS= read -r -d '' d; do
    if python3 -I -B "$here/lib/scrub.py" rmcell "$d" >/dev/null 2>&1; then echo "run.sh: startup sweep removed stale cell $d (older than $min min)" >&2
    else echo "run.sh: startup sweep could NOT remove stale cell $d: it may still hold a credential copy; remove it by hand" >&2; fi
  done < <(python3 -I -B "$here/lib/scrub.py" stale "$TMPDIR" eval-cell. "$min")
}
sweep_stale
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-cell.XXXXXX")" || die "mktemp failed"
# LIVENESS MARKER: this run's pid and that pid's start time (raw `ps -o lstart=`, LC_ALL=C; portable to macOS and Linux). The sweep (scrub.py
# stale) skips a cell whose marker names a pid that is alive AND whose current start time is the stored one, so a long cell is never swept
# under its own run and a reused pid does not protect a dead cell. An unreadable/unparseable marker proves nothing: the age rule applies.
# It sits in the cell ROOT, which the seatbelt profile never lets the agent write; with the sandbox OFF the agent runs as the user, can
# forge it and so keep its own cell from being swept (it can do anything else as the user too: row sandbox:off, never graded).
( umask 077; printf '%s\n%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//')" >"$tmp/.eval-live" )
child=""
scrub_fail=""
tampered=""   # first top-level cell child (or credential path) found replaced by a link / special file: row error cell-tampered
# scrub_note <scrub.py output>: record `tampered <name>` lines and the `survivor: <name>` line of a failed removal.
scrub_note() {
  local l
  while IFS= read -r l; do
    case "$l" in
      "tampered "*) tampered="${tampered:-${l#tampered }}" ;;
      "survivor: "*) scrub_fail="${scrub_fail:-${l#survivor: }}" ;;
    esac
  done <<<"$1"
}
# CREDENTIAL IN WHAT THE HARNESS KEEPS (lib/redact.py). The adapters write the secret set (the staged credential file's bytes and the
# JSON string values >= 16 chars inside it, the value of the authentication variable they export; each also as base64, url-safe
# base64 and hex) to $EVAL_SECRETS_FILE, a 0600 file in the cell root. Before the row is written: the harness's captures (prompt,
# answer, usage, host log, grader output) are redacted in place, `work` is scanned (EVAL_KEEP only: a hit DELETES the file), and
# every string of the row goes through the filter. A hit makes the row error credential-in-output (or credential-in-kept-files),
# pass false, no grading metrics, one loud stderr line, exit 4. The helper gets the secrets on a descriptor, never in argv, and runs
# with the authentication variables removed from its environment.
secf="$tmp/.secrets" credf="$tmp/cred-paths.txt"
( umask 077; : >"$secf" )
export EVAL_SECRETS_FILE="$secf"
redact() { env -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN python3 -I -B "$here/lib/redact.py" "$@"; }
# scrub_cell: the agent-reachable part of the cell (home gocache celltmp + the adapter's sbx.*, and any other name; `work` too unless
# EVAL_KEEP) is removed by scrub.py rmcell, keeping only the harness files the row still needs. On failure scrub_fail names the first
# path that remains.
scrub_cell() {
  local o keepwork=()
  [[ "${EVAL_KEEP:-0}" == 1 ]] && keepwork=(--keep work)
  o="$(python3 -I -B "$here/lib/scrub.py" rmcell "$tmp" --keep prompt.txt --keep agent-output.txt --keep usage.json --keep host.log \
    --keep grade.out --keep grade.err --keep cell-tampered --keep .eval-keep --keep .eval-live --keep .secrets --keep cred-paths.txt ${keepwork[@]+"${keepwork[@]}"} 2>&1)" \
    || scrub_fail="${scrub_fail:-$tmp}"
  scrub_note "$o"
  if [[ -n "$scrub_fail" ]]; then echo "run.sh: SCRUB FAILED: $scrub_fail is still on disk and may hold a copy of the credential; remove $tmp by hand (error: scrub-failed)" >&2; fi
}
cleanup() {
  [[ -n "$scrub_fail" ]] || scrub_cell   # the normal path already ran it before the row was written (idempotent)
  if [[ "${EVAL_KEEP:-0}" == 1 ]]; then
    local f
    for f in .secrets cred-paths.txt .eval-live; do python3 -I -B "$here/lib/scrub.py" rmname "$tmp" "$f" >/dev/null 2>&1 || echo "run.sh: SCRUB FAILED: $tmp/$f could not be removed (error: scrub-failed)" >&2; done
    echo "run.sh: kept $tmp" >&2
  elif ! python3 -I -B "$here/lib/scrub.py" rmcell "$tmp" >/dev/null 2>&1; then echo "run.sh: SCRUB FAILED: $tmp could not be removed and may hold a credential copy (error: scrub-failed)" >&2; exit 4; fi
}
trap cleanup EXIT
# TERM/INT/HUP: take the child (limited.py -> host process group) down FIRST,
# then exit so the EXIT trap removes the temp dirs. `wait` lets the trap fire now.
onsig() {   # $1 = the exit code: 143 for TERM/INT, 129 for HUP (a terminal hangup), the conventional 128+signal
  if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  exit "$1"
}
trap 'onsig 143' TERM INT
trap 'onsig 129' HUP
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
ucls="" uerr=""   # the parser's verdict on the stream (lib/parse_*.py contract): an error class, or a usage_error on a valid answer

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
    # The parser's verdict is in the usage file (written by the adapter, outside the cell). A stream failure (exit 0 incomplete included:
    # the adapter maps it to 3) is an error row, NOT graded, usage null; a usage-invalid answer is graded, its row carries usage_error.
    if [[ -s "$usagef" ]]; then
      { IFS= read -r ucls; IFS= read -r uerr; } < <(python3 -I -B -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
d=d if isinstance(d,dict) else {}
for k in ("error","usage_error"):
    v=d.get(k); print(" ".join(v.split())[:250] if isinstance(v,str) else "")' "$usagef" 2>/dev/null) || true
    fi
    case "$host_rc" in 0|3|4|5|6|82)
      if [[ -n "$ucls" ]]; then err="$ucls"; can_grade=0; fi ;;
    esac
    # the adapter found a cell name replaced while it scrubbed the credential (it writes the name beside the cell, which the agent cannot write)
    if [[ -s "$tmp/cell-tampered" ]]; then tampered="$(head -n 1 "$tmp/cell-tampered" | cut -c1-200)"; can_grade=0; fi
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

# the staged credential must not be in anything the harness keeps: redact the captures, scan `work` (EVAL_KEEP), filter the error text
cred_places=0 cred_kept=0 cred_scanfail=0 err_before="" err_f="$err"
count_of() { local n; n="$(sed -n 's/^total //p' <<<"$1" | tail -n 1)"; echo "${n:-0}"; }
credential_phase() {
  [[ -s "$secf" ]] || return 0
  local o rc l n
  o="$(redact scan-file 3 "$promptf" "$outf" "$usagef" "$hostlog" "$gradeo" "$gradee" 3<"$secf" 2>/dev/null)"; rc=$?
  case $rc in 0) ;; 3) cred_places=$(( cred_places + $(count_of "$o") )) ;; *) cred_scanfail=1 ;; esac
  if [[ "${EVAL_KEEP:-0}" == 1 && -d "$workdir" ]]; then
    o="$(redact scan-tree 3 "$workdir" 3<"$secf" 2>/dev/null)"; rc=$?
    case $rc in 0|1|3) ;; *) cred_scanfail=1 ;; esac
    while IFS= read -r l; do
      case "$l" in
        "deleted "*) printf '%s\n' "${l#deleted }" >>"$credf"; cred_kept=$((cred_kept + 1)) ;;
        "survivor "*) scrub_fail="${scrub_fail:-$workdir/${l#survivor }}" ;;
      esac
    done <<<"$o"
  fi
  if [[ -n "$err" ]]; then
    err_f="$(printf '%s' "$err" | redact filter 3 3<"$secf" 2>/dev/null)"; rc=$?
    case $rc in 0) ;; 3) (( cred_places > 0 )) || cred_places=1 ;; *) cred_scanfail=1; err_f="" ;; esac
  fi
}
credential_phase
# the cell is removed BEFORE the row so a removal that fails is IN the row; the harness files (output, usage, grade) stay until exit
scrub_cell
cred_error() {   # the row error of a credential finding (it REPLACES any earlier text, which may itself have carried the secret)
  err_before="$err_f"
  if (( cred_places > 0 )); then err="credential-in-output"; else err="credential-in-kept-files: $cred_kept file(s)"; fi
  gradeo="" grade_rc=-1   # not graded: no grader metrics reach the row
  echo "CREDENTIAL IN OUTPUT -- redacted in $((cred_places + cred_kept)) place(s)" >&2
}
if (( cred_scanfail )); then err="credential-scan-failed"; err_before=""; gradeo="" grade_rc=-1; echo "CREDENTIAL SCAN FAILED -- the harness's captures could not be checked for the credential (error: credential-scan-failed)" >&2
elif (( cred_places > 0 || cred_kept > 0 )); then cred_error; fi
if [[ -n "$scrub_fail" ]]; then err="scrub-failed: $scrub_fail"
elif [[ -n "$tampered" ]] && (( ! cred_scanfail && cred_places == 0 && cred_kept == 0 )); then err="cell-tampered: $tampered"; fi   # an error row: pass false, exit status as for any other row error (0)

dur="$(python3 -I -B -c "print($t1 - $t0)")"
ROW=""
# make_row: the row text in $ROW, every string of it through the filter (a secret anywhere in it, e.g. a name in an error, is replaced);
# sets row_hit=1 when the filter changed it. ROW is built in a variable, never in a file.
make_row() {
  local r ann=() rc
  r="$(python3 -I -B "$here/lib/row.py" --task-json "$task/task.json" --task-id "$task_id" --skill "$skill" \
    --arm "$arm" --host "$host" --model "$model" --rep "$rep" --exit "$host_rc" \
    --grade-exit "$grade_rc" --timed-out "$timed_out" --duration "$dur" \
    --usage-file "$usagef" --grade-file "$gradeo" --sandbox "$sandbox" --order-seed "$order_seed" --skill-sha "$skill_sha" \
    --harness-sha "$harness_sha" --output-file "$outf" --schema "$schema_applies" --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --error="$err" --out /dev/stdout)" || return 1
  if [[ -n "$uerr" && -z "$ucls" ]]; then   # a valid answer with unreadable usage: the row says so (tokens/cost are already null)
    r="$(printf '%s\n' "$r" | python3 -I -B -c 'import json,sys
d=json.loads(sys.stdin.read()); d["usage_error"]=sys.argv[1]; print(json.dumps(d,sort_keys=True))' "$uerr")" || return 1
  fi
  [[ -n "$err_before" ]] && ann+=(--error-before "$err_before")
  (( cred_kept > 0 )) && ann+=(--paths-file "$credf")
  if (( ${#ann[@]} )); then r="$(printf '%s\n' "$r" | redact annotate "${ann[@]}")" || return 1; fi
  row_hit=0
  if [[ -s "$secf" ]] && (( ! cred_scanfail )); then
    r="$(printf '%s\n' "$r" | redact filter 3 3<"$secf" 2>/dev/null)"; rc=$?
    case $rc in 0) ;; 3) row_hit=1 ;; *) return 1 ;; esac
  fi
  ROW="$r"
}
row_hit=0
make_row || { echo "run.sh: could not write the row" >&2; exit 1; }
if (( row_hit )) && (( cred_places == 0 && cred_kept == 0 )); then   # the secret was only in the row (e.g. a metric or a name): same finding
  cred_places=1; cred_error; make_row || { echo "run.sh: could not write the row" >&2; exit 1; }
fi
printf '%s\n' "$ROW" >>"$out" || { echo "run.sh: could not write the row" >&2; exit 1; }
[[ -z "$scrub_fail" ]] || exit 4
(( cred_scanfail || cred_places > 0 || cred_kept > 0 )) && exit 4
[[ $auth_fail -eq 0 ]] || exit 3
