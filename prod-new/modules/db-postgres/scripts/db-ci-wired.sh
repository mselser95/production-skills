#!/usr/bin/env bash
# db-ci-wired.sh - check that the CI workflow's job `db` has a `make db-test` step that, when the
# change-detection step says so, runs with nothing on it that could make it pass without running.
#
#   db-ci-wired.sh [WORKFLOW.yaml]       (default .github/workflows/pr.yaml)
#
# What is claimed, exactly: job `db` has (1) the PINNED change-detection step (id `changed`, compared by
# equality: its `env` and its whole `run`, only `name` is free; the gate's `if` reads its output), (2) the
# PyYAML and image pre-pull steps, and (3) one `make db-test` step whose `if` reads that step's output and
# which carries only the key allow-lists below. NOT claimed: shell in EARLIER steps is not judged (a step
# that rewrites the Makefile or a dotfile), and third-party `uses:` actions before the gate are not pinned;
# review covers those. If the change-detection step is edited on purpose, update CHANGED_PIN below.
# A grep for `run: make db-test` is satisfied by a commented line or by a step
# that can never run, or can never fail the job. This PARSES the workflow (python3 +
# PyYAML) and requires, in a job named `db`:
#   - exactly ONE step whose `run` mentions `db-test`, and that `run` (trailing whitespace
#     stripped) is EXACTLY the single line `make db-test` (so `set +e` ... `exit 0` around it,
#     or a second `make db-test || true` step, is refused);
#   - ALLOW-LISTS (anything else is refused, naming the key; a deny-list always misses one key):
#       the `make db-test` STEP carries only `name`, `run`, `if`, `id`, `timeout-minutes` (an
#       integer), and the `if` is absent or exactly `steps.changed.outputs.run == 'true'` (an
#       allow-list of ONE expression: `always() && false` and friends are refused);
#       every step BEFORE it carries only `name`, `uses`, `with`, `run`, `if`, `id`, `env`,
#       `continue-on-error` (the shipped workflow uses the first six and `env`; the last is
#       judged below); an `env` there may not name MAKE, MAKEFLAGS, MFLAGS, GNUMAKEFLAGS, SHELL,
#       PATH, BASH_ENV or ENV; no `run` line of the job mentions GITHUB_ENV or GITHUB_PATH (a
#       `echo MAKEFLAGS=-n >> "$GITHUB_ENV"` turns `make db-test` into a no-op for the later step);
#       the JOB carries only `name`, `runs-on`, `timeout-minutes`, `steps` (no `env`, `defaults`,
#       `if`, `needs`, `container`, `services`, `strategy`, `continue-on-error`);
#       the WORKFLOW has no top-level `env` and no `defaults`;
#   - `timeout-minutes` of the job is an integer >= 10;
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

# THE PIN: the step that decides whether the gate runs. The gate's `if` reads `steps.changed.outputs.run`;
# a gate is only as live as that output, so the step that writes it is compared by EQUALITY (id, `if`,
# `env` and the full `run`; only `name` is free) against this copy. One edit to it (it always writes
# run=false, its path filter has a typo, its id is renamed) turns the gate into a step that never runs
# with the job still green. If the workflow's step is changed on purpose, update this copy in the same PR.
CHANGED_ID = "changed"
CHANGED_PIN = {
    "id": "changed",
    "env": {'EVENT': '${{ github.event_name }}', 'BASE': '${{ github.event.pull_request.base.sha }}'},
    "run": r"""if [ "$EVENT" != "pull_request" ]; then
  echo "run=true" >> "$GITHUB_OUTPUT"
  echo "db: running (event $EVENT)"
  exit 0
fi
files=$(git diff --name-only "$BASE" HEAD) || { echo "db: cannot diff against $BASE" >&2; exit 1; }
if grep -qE '^(prod-new/modules/db-postgres/|Makefile$|\.github/workflows/pr\.yaml$)' <<<"$files"; then
  echo "run=true" >> "$GITHUB_OUTPUT"
  echo "db: running (database module, Makefile or workflow changed)"
else
  echo "run=false" >> "$GITHUB_OUTPUT"
  echo "db: skipped: no database change"
fi
""",
}

STEP_KEYS = {"name", "run", "if", "id", "timeout-minutes"}
PRE_KEYS = {"name", "uses", "with", "run", "if", "id", "env", "continue-on-error"}
JOB_KEYS = {"name", "runs-on", "timeout-minutes", "steps"}
BAD_ENV = re.compile(r"(MAKE|MAKEFLAGS|MFLAGS|GNUMAKEFLAGS|SHELL|PATH|BASH_ENV|ENV)\Z")

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
for key in ("env", "defaults"):
    if isinstance(doc, dict) and key in doc:
        refuse(f"the workflow has a top-level `{key}` (it can change how every `run` executes, `make db-test` included)")
for key in job:
    if key not in JOB_KEYS:
        refuse(f"job `db` has the key `{key}` (allowed: {', '.join(sorted(JOB_KEYS))}; any other key can switch the job off or change how make runs)")
steps = job.get("steps") or []
if not all(isinstance(s, dict) for s in steps):
    refuse("job `db` has a step that is not a mapping")
def lines_of(s):
    return [l.strip() for l in s["run"].splitlines()] if isinstance(s, dict) and isinstance(s.get("run"), str) else []


hits = [s for s in steps if isinstance(s, dict) and isinstance(s.get("run"), str) and "db-test" in s["run"]]
if len(hits) != 1:
    refuse(f"job `db` must have exactly one step whose run mentions db-test (found {len(hits)})")
if hits[0]["run"].rstrip() != "make db-test":
    refuse("the db-test step's run must be exactly the single line `make db-test` (no `set +e`, `|| true`, `exit 0` or other lines)")
for key in hits[0]:
    if key not in STEP_KEYS:
        refuse(f"the `make db-test` step has the key `{key}` (allowed: {', '.join(sorted(STEP_KEYS))}; any other key changes what make does or how a failure is reported)")
tmo = hits[0].get("timeout-minutes")
if "timeout-minutes" in hits[0] and (isinstance(tmo, bool) or not isinstance(tmo, int)):
    refuse("the `make db-test` step's timeout-minutes is not an integer")
if "if" in hits[0] and hits[0]["if"] != STEP_IF:
    refuse(f"the `make db-test` step's `if` is not exactly `{STEP_IF}`")
live = hits
first = steps.index(live[0])
# the change-detection step: exactly one, pinned by equality, and BEFORE the gate that reads its output
cands = [i for i, s in enumerate(steps) if s.get("id") == CHANGED_ID]
if len(cands) != 1:
    refuse(f"job `db` must have exactly one step with id `{CHANGED_ID}` (found {len(cands)}): the step that decides whether db-test runs; if the change is intended, update the pin in scripts/db-ci-wired.sh")
_ch = steps[cands[0]]
if {k: v for k, v in _ch.items() if k != "name"} != CHANGED_PIN:
    refuse(f"the step that decides whether db-test runs (step {_ch.get('name', '(unnamed)')!r}, id `{CHANGED_ID}`) differs from the pinned text; if the change is intended, update the pin in scripts/db-ci-wired.sh")
if "if" in hits[0]:
    _ref = re.findall(r"steps\.([A-Za-z0-9_-]+)\.", str(hits[0]["if"]))
    if (_ref and _ref != [CHANGED_ID]) or cands[0] > first:   # (an `if` with no step reference is the STEP_IF rule's business)
        refuse(f"the `make db-test` step's `if` must read the output of the step `{CHANGED_ID}`, and that step must run BEFORE it (else the output is empty and db-test never runs)")
for s in steps[:first]:
    for key in s:
        if key not in PRE_KEYS:
            refuse(f"step {s.get('name', '(unnamed)')!r} before `make db-test` has the key `{key}` (allowed: {', '.join(sorted(PRE_KEYS))})")
    env = s.get("env")
    if env is not None and not isinstance(env, dict):
        refuse(f"step {s.get('name', '(unnamed)')!r} has an `env` that is not a mapping")
    for k in (env or {}):
        if BAD_ENV.match(str(k)):
            refuse(f"step {s.get('name', '(unnamed)')!r} sets env `{k}` (it changes how make or the shell runs)")
for s in steps:
    if any("GITHUB_ENV" in l or "GITHUB_PATH" in l for l in lines_of(s)):
        refuse(f"step {s.get('name', '(unnamed)')!r} mentions GITHUB_ENV or GITHUB_PATH (it can set MAKEFLAGS, SHELL or PATH for `make db-test`)")
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
