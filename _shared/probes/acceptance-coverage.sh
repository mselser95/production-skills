#!/usr/bin/env bash
# acceptance-coverage.sh — an acceptance spec is complete, approved, and every
# case is traced to a test (and every test to a case).
#
# WHY THIS EXISTS. "Comprehensive" acceptance coverage is only as good as the
# matrix behind it (_shared/formats/acceptance-spec.md), and a matrix nobody
# checks decays into the happy path plus two errors with every other row
# quietly empty. So the structure is checked by a script, not by a reviewer
# reading YAML: every matrix row filled or `na` with a reason, every case with
# given/when/then/observe/mutation, the approval recorded, and the traceability
# closed in BOTH directions -- a case with no test is uncovered behaviour, a
# test citing an id that does not exist is an assertion whose oracle nobody
# approved.
#
# What it does NOT check, said so nobody reads more into a green line: that the
# tests PASS (the repo's own test command does), that each test goes RED under
# its case's mutation (prove-mutation.sh does, at authoring time), or that the
# matrix was filled WELL (prod-review judges that).
#
# Usage: acceptance-coverage.sh [--spec-only] SPEC [TEST_ROOT]
#   --spec-only  validate the spec alone (before approval and before tests
#                exist); approval may be `pending`
#   TEST_ROOT    where tests are searched (default: the spec's git toplevel)
# Exit:  0 ok · 1 a check failed · 2 nothing checked / unusable input
set -uo pipefail

spec_only=0
[[ "${1:-}" == "--spec-only" ]] && { spec_only=1; shift; }
spec="${1:-}"
[[ -n "$spec" && -r "$spec" ]] || { echo "acceptance-coverage: no readable spec given -- nothing checked is not a pass" >&2; exit 2; }
root="${2:-$(cd "$(dirname "$spec")" && git rev-parse --show-toplevel 2>/dev/null || dirname "$spec")}"
command -v python3 >/dev/null || { echo "acceptance-coverage: python3 unavailable -- unparsed is not valid" >&2; exit 2; }

SPEC="$spec" ROOT="$root" SPEC_ONLY="$spec_only" python3 - <<'PY'
import os, re, sys
try:
    import yaml
except ImportError:
    print("acceptance-coverage: PyYAML unavailable -- unparsed is not valid", file=sys.stderr); sys.exit(2)

ROWS = ["happy_path", "input_classes", "declared_errors", "authorization",
        "idempotency_retry", "state_transitions", "ordering_concurrency",
        "durability_restart", "compatibility", "feature_interaction", "observability"]
FIELDS = ["given", "when", "then", "observe", "mutation"]
OBSERVE = {"response", "event", "readback", "metric", "log"}

spec, root, spec_only = os.environ["SPEC"], os.environ["ROOT"], os.environ["SPEC_ONLY"] == "1"
fails = []
def fail(m): fails.append(m)

try:
    d = yaml.safe_load(open(spec))
except Exception as e:
    print(f"acceptance-coverage: spec does not parse: {e}", file=sys.stderr); sys.exit(2)
if not isinstance(d, dict):
    print("acceptance-coverage: spec is not a mapping", file=sys.stderr); sys.exit(2)

feature = str(d.get("feature") or "")
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", feature):
    fail(f"feature '{feature}' is missing or not kebab-case -- tests cite it as acceptance:<feature>/AC-NN")
if not d.get("surface"):
    fail("surface is empty -- an acceptance case with no public entrypoint is a unit test in disguise")

approved = str(d.get("approved_by") or "pending")
if approved == "pending" and not spec_only:
    fail("approved_by is pending -- tests are written against an APPROVED spec only")

cases = d.get("cases") or []
if not cases:
    print("acceptance-coverage: spec has zero cases -- nothing checked is not a pass", file=sys.stderr); sys.exit(2)
ids = []
for c in cases:
    cid = str((c or {}).get("id") or "")
    if not re.fullmatch(r"AC-\d+", cid):
        fail(f"case id '{cid}' is not AC-NN"); continue
    if cid in ids: fail(f"{cid} is duplicated")
    ids.append(cid)
    for f in FIELDS:
        if not str(c.get(f) or "").strip():
            fail(f"{cid} has no {f}:" + (" -- a case whose breaking change is unnamed cannot be proven to have teeth" if f == "mutation" else ""))
    if c.get("observe") and str(c["observe"]) not in OBSERVE:
        fail(f"{cid} observe '{c['observe']}' is not one of {sorted(OBSERVE)}")
idset = set(ids)

m = d.get("matrix") or {}
referenced = set()
for r in ROWS:
    v = m.get(r)
    if v is None:
        fail(f"matrix row '{r}' is missing -- every row is filled or na with a reason"); continue
    if isinstance(v, dict) and "na" in v:
        if not str(v.get("na") or "").strip():
            fail(f"matrix row '{r}' is na with no reason")
        continue
    if not isinstance(v, list) or not v:
        fail(f"matrix row '{r}' is empty -- list case ids or write na: <reason>"); continue
    for x in v:
        if str(x) not in idset: fail(f"matrix row '{r}' cites {x}, which is not a case")
        referenced.add(str(x))
for u in sorted(idset - referenced, key=lambda s: int(s[3:])):
    fail(f"{u} is in no matrix row -- a case outside the matrix is coverage nobody can audit")

tested = {}
if not spec_only and feature:
    pat = re.compile(r"acceptance:" + re.escape(feature) + r"/(AC-\d+)")
    spec_abs = os.path.abspath(spec)
    for dp, dns, fns in os.walk(root):
        dns[:] = [x for x in dns if x not in (".git", "node_modules", "vendor", ".prod")]
        for fn in fns:
            p = os.path.join(dp, fn)
            if os.path.abspath(p) == spec_abs: continue
            try:
                if os.path.getsize(p) > 2_000_000: continue   # binaries, fixtures, dumps
                txt = open(p, errors="ignore").read()
            except OSError: continue
            for cid in pat.findall(txt):
                tested.setdefault(cid, set()).add(os.path.relpath(p, root))
    for cid in ids:
        if cid not in tested: fail(f"{cid} has no test citing acceptance:{feature}/{cid}")
    for cid in sorted(set(tested) - idset):
        fail(f"tests cite acceptance:{feature}/{cid}, which the spec does not define: {sorted(tested[cid])[0]}")

for f in fails: print(f"  FAIL  {f}")
if fails:
    print(f"acceptance-coverage: {len(fails)} failure(s) in {feature or spec}", file=sys.stderr); sys.exit(1)
na = sum(1 for r in ROWS if isinstance(m.get(r), dict))
mode = "spec only" if spec_only else f"{len(tested)} case(s) traced to tests"
print(f"acceptance-coverage: ok -- {feature}: {len(ids)} case(s), {len(ROWS) - na}/{len(ROWS)} matrix rows covered ({na} na), {mode}, approved_by={approved}")
PY
