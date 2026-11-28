#!/usr/bin/env bash
# db-ci-wired.sh - prove the CI workflow really runs `make db-test`.
#
#   db-ci-wired.sh [WORKFLOW.yaml]       (default .github/workflows/pr.yaml)
#
# A grep for `run: make db-test` is satisfied by a commented line or by a step
# that can never run, or can never fail the job. This PARSES the workflow (python3 +
# PyYAML) and requires, in a job named `db`:
#   - exactly ONE step whose `run` mentions `db-test`, and that `run` (trailing whitespace
#     stripped) is EXACTLY the single line `make db-test` (so `set +e` ... `exit 0` around it,
#     or a second `make db-test || true` step, is refused);
#   - that step has no `shell`, no `working-directory`, no `continue-on-error` (absent or literal
#     false), and an `if` that is absent or exactly `steps.changed.outputs.run == 'true'` (an
#     allow-list of ONE expression: `always() && false` and friends are refused);
#   - the JOB has no `if` and no `continue-on-error`, and `timeout-minutes` is an integer >= 10;
#   - before it, a live step whose run has a line matching one anchored pattern for installing
#     PyYAML (`pip install [--quiet] [quote]PyYAML[==x.y][quote]`, nothing after it), and one with
#     a `docker pull` line; each has no continue-on-error other than false and the SAME `if`
#     as the `make db-test` step (compared as strings).
# Exit: 0 wired / 1 not wired / 2 python3 or PyYAML missing, file unreadable
# (nothing was checked; never "unchecked = ok").
set -uo pipefail
wf="${1:-.github/workflows/pr.yaml}"
[[ -r $wf ]] || { echo "db-ci-wired: cannot read $wf" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "db-ci-wired: python3 is not available, so $wf cannot be parsed" >&2; exit 2; }
python3 -B -c 'import yaml' 2>/dev/null || { echo "db-ci-wired: PyYAML is not importable, so $wf cannot be parsed" >&2; exit 2; }
exec python3 -B - "$wf" <<'PY'
import re, sys, yaml

FALSE = {"false", "${{ false }}", "${{false}}", "0"}
STEP_IF = "steps.changed.outputs.run == 'true'"   # the one `if` the shipped workflow gates its steps with

def never(v):
    return v is False or str(v).strip().lower() in FALSE

def soft(v):  # continue-on-error: anything but an explicit false lets a red step pass
    return not (v is None or never(v))

def refuse(msg):
    print(f"db-ci-wired: FAIL {msg}", file=sys.stderr); sys.exit(1)

path = sys.argv[1]
try:
    doc = yaml.safe_load(open(path))
except yaml.YAMLError as e:
    print(f"db-ci-wired: {path} is not valid YAML: {e}", file=sys.stderr)
    sys.exit(2)
jobs = (doc or {}).get("jobs") if isinstance(doc, dict) else None
job = jobs.get("db") if isinstance(jobs, dict) else None
if not isinstance(job, dict):
    refuse(f"{path} has no job `db`")
if "if" in job:
    refuse("job `db` has an `if` (no job-level condition is allowed: it can switch the whole job off)")
if soft(job.get("continue-on-error")):
    refuse("job `db` has continue-on-error")
steps = job.get("steps") or []
def lines_of(s):
    return [l.strip() for l in s["run"].splitlines()] if isinstance(s, dict) and isinstance(s.get("run"), str) else []


hits = [s for s in steps if isinstance(s, dict) and isinstance(s.get("run"), str) and "db-test" in s["run"]]
if len(hits) != 1:
    refuse(f"job `db` must have exactly one step whose run mentions db-test (found {len(hits)})")
if hits[0]["run"].rstrip() != "make db-test":
    refuse("the db-test step's run must be exactly the single line `make db-test` (no `set +e`, `|| true`, `exit 0` or other lines)")
for key in ("shell", "working-directory"):
    if key in hits[0]:
        refuse(f"the `make db-test` step sets `{key}` (it can change how a failure is reported or where it runs)")
if soft(hits[0].get("continue-on-error")):
    refuse("the `make db-test` step has continue-on-error")
if "if" in hits[0] and hits[0]["if"] != STEP_IF:
    refuse(f"the `make db-test` step's `if` is not exactly `{STEP_IF}`")
live = hits
first = steps.index(live[0])
test_if = live[0].get("if")


def live_step(s):
    # not allowed to fail, and gated by the SAME expression as `make db-test`
    # (any other `if` can turn the step off while the test still runs: `if: ${{ 1 == 2 }}`)
    return not soft(s.get("continue-on-error")) and s.get("if") == test_if


def before(pred):
    return [i for i, s in enumerate(steps[:first]) if isinstance(s, dict) and live_step(s) and any(pred(l) for l in lines_of(s))]


PIP = re.compile(r"(sudo )?(python3 -m )?pip install( --quiet| -q)? ['\"]?PyYAML(==[0-9.]+)?['\"]?\Z")
if not before(lambda l: PIP.match(l)):
    refuse("job `db` has no live step before `make db-test` with a line that is exactly a `pip install` of PyYAML (parity-check.sh needs it)")
if not before(lambda l: re.match(r"docker\s+pull\b", l)):
    refuse("job `db` has no live step before `make db-test` with a `docker pull` line (the images named by image.lock)")
tm = job.get("timeout-minutes")
if isinstance(tm, bool) or not isinstance(tm, int) or tm < 10:
    refuse("job `db` needs an integer timeout-minutes >= 10 (a cold pull and five container runs)")
print(f"db-test is run by job db, step {live[0].get('name', '(unnamed)')!r}")
PY
