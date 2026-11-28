#!/usr/bin/env bash
# db-ci-wired.sh - prove the CI workflow really runs `make db-test`.
#
#   db-ci-wired.sh [WORKFLOW.yaml]       (default .github/workflows/pr.yaml)
#
# A grep for `run: make db-test` is satisfied by a commented line or by a step
# that can never run. This PARSES the workflow (python3 + PyYAML) and requires:
#   - a job named `db`;
#   - in it, a step with a `run` LINE that is exactly `make db-test`;
#   - neither that step nor the job has `if:` set to a constant false or
#     `continue-on-error:` set to anything but false. (A step `if` that is an
#     expression, such as the change filter the workflow uses, is allowed.)
# and the two steps `make db-test` cannot run without (a cold runner has no PyYAML and no
# exporter image), plus the job's time budget:
#   - a step BEFORE it with a run line that starts (after optional `sudo ` / `python3 -m `) with
#     `pip install` and names PyYAML (`echo pip install PyYAML` does not count);
#   - a step before it with a run line that starts with `docker pull`;
#   - neither of those steps has continue-on-error other than false, and each has the SAME `if`
#     expression as the `make db-test` step (compared as strings; a different one, such as
#     `${{ 1 == 2 }}`, could switch the step off while the test still runs);
#   - `timeout-minutes` of the job is an integer >= 10 (a cold pull plus five container runs).
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

def never(v):
    return v is False or str(v).strip().lower() in FALSE

def soft(v):  # continue-on-error: anything but an explicit false lets a red step pass
    return not (v is None or never(v))

path = sys.argv[1]
try:
    doc = yaml.safe_load(open(path))
except yaml.YAMLError as e:
    print(f"db-ci-wired: {path} is not valid YAML: {e}", file=sys.stderr)
    sys.exit(2)
jobs = (doc or {}).get("jobs") if isinstance(doc, dict) else None
job = jobs.get("db") if isinstance(jobs, dict) else None
if not isinstance(job, dict):
    print(f"db-ci-wired: FAIL {path} has no job `db`", file=sys.stderr); sys.exit(1)
if "if" in job and never(job["if"]):
    print("db-ci-wired: FAIL job `db` has a constant-false `if`", file=sys.stderr); sys.exit(1)
if soft(job.get("continue-on-error")):
    print("db-ci-wired: FAIL job `db` has continue-on-error", file=sys.stderr); sys.exit(1)
steps = job.get("steps") or []
def lines_of(s):
    return [l.strip() for l in s["run"].splitlines()] if isinstance(s, dict) and isinstance(s.get("run"), str) else []


hits = [s for s in steps if "make db-test" in lines_of(s)]
if not hits:
    print("db-ci-wired: FAIL job `db` has no step with a line that is exactly `make db-test`", file=sys.stderr); sys.exit(1)
live = [s for s in hits if not ("if" in s and never(s["if"])) and not soft(s.get("continue-on-error"))]
if not live:
    print("db-ci-wired: FAIL the `make db-test` step has a constant-false `if` or continue-on-error", file=sys.stderr); sys.exit(1)
first = steps.index(live[0])
test_if = live[0].get("if")


def live_step(s):
    # not skippable and not allowed to fail, and gated by the SAME expression as `make db-test`
    # (any other `if` can turn the step off while the test still runs: `if: ${{ 1 == 2 }}`)
    return not soft(s.get("continue-on-error")) and s.get("if") == test_if


def before(pred):
    return [i for i, s in enumerate(steps[:first]) if isinstance(s, dict) and live_step(s) and any(pred(l) for l in lines_of(s))]


PIP = re.compile(r"(?:sudo\s+)?(?:python3?\s+-m\s+)?pip3?\s+install\b.*PyYAML")
if not before(lambda l: PIP.match(l)):
    print("db-ci-wired: FAIL job `db` has no live step before `make db-test` with a line that starts with `pip install` and names PyYAML (parity-check.sh needs it)", file=sys.stderr); sys.exit(1)
if not before(lambda l: re.match(r"docker\s+pull\b", l)):
    print("db-ci-wired: FAIL job `db` has no live step before `make db-test` with a `docker pull` line (the images named by image.lock)", file=sys.stderr); sys.exit(1)
tm = job.get("timeout-minutes")
if isinstance(tm, bool) or not isinstance(tm, int) or tm < 10:
    print("db-ci-wired: FAIL job `db` needs an integer timeout-minutes >= 10 (a cold pull and five container runs)", file=sys.stderr); sys.exit(1)
print(f"db-test is run by job db, step {live[0].get('name', '(unnamed)')!r}")
PY
