#!/usr/bin/env bash
# acceptance-gap.sh — the visible-minus-held-out gap: the detector for an
# implementation built to the tests it could see.
#
# WHY THIS EXISTS. Agents saturate the tests they can see and fail held-out
# ones (SpecBench 2605.21384), and a ~perfect score on a visible oracle can sit
# over a dead-code delivery (2606.28430). The acceptance spec splits cases into
# lanes (_shared/formats/acceptance-spec.md); the orchestrator runs held_out only
# after the implementer hands back. This probe compares the two pass-rates.
#
# Usage: acceptance-gap.sh SPEC VISIBLE_RESULTS HELDOUT_RESULTS
#   results files: lines `AC-NN PASS|FAIL` (any runner can emit them); blank
#   lines and `#` comments are ignored.
# Gap rule (a/b = visible pass/total, c/d = held_out pass/total):
#   gap = a*d/b - c  -- the held-out cases failed beyond what the visible rate
#   predicts. BLOCKER when gap > 1 case, or when any held_out FAILs while every
#   visible case passed. Otherwise OK.
# Output: one line `acceptance-gap: visible a/b held_out c/d gap=<cases> verdict=OK|BLOCKER`
# Exit:  0 OK · 1 BLOCKER · 2 unusable/unmeasured input (an id in the wrong
#        file, an unknown id, a duplicate, a spec case with no result, an empty
#        results file: nothing measured is not a pass)
set -uo pipefail

spec="${1:-}" vis="${2:-}" held="${3:-}"
for f in "$spec" "$vis" "$held"; do
  [[ -n "$f" && -r "$f" ]] || { echo "acceptance-gap: usage: SPEC VISIBLE_RESULTS HELDOUT_RESULTS (unreadable: '${f}')" >&2; exit 2; }
done
command -v python3 >/dev/null || { echo "acceptance-gap: python3 unavailable -- unparsed is not valid" >&2; exit 2; }

SPEC="$spec" VIS="$vis" HELD="$held" python3 - <<'PY'
import os, re, sys
try:
    import yaml
except ImportError:
    print("acceptance-gap: PyYAML unavailable -- unparsed is not valid", file=sys.stderr); sys.exit(2)

def die(m):
    print(f"acceptance-gap: {m}", file=sys.stderr); sys.exit(2)

try:
    d = yaml.safe_load(open(os.environ["SPEC"]))
except Exception as e:
    die(f"spec does not parse: {e}")
lane = {}
for c in (d.get("cases") if isinstance(d, dict) else None) or []:
    cid, ln = str((c or {}).get("id") or ""), str((c or {}).get("lane") or "")
    if ln not in ("visible", "held_out"):
        die(f"{cid or '?'} has no valid lane in the spec")
    lane[cid] = ln
if not lane:
    die("spec has no cases -- nothing measured is not a pass")

def load(path, want):
    res = {}
    for n, raw in enumerate(open(path), 1):
        line = raw.strip()
        if not line or line.startswith("#"): continue
        m = re.fullmatch(r"(AC-\d+)\s+(PASS|FAIL)", line)
        if not m: die(f"{path}:{n}: '{line}' is not 'AC-NN PASS|FAIL'")
        cid, r = m.groups()
        if cid not in lane: die(f"{path}:{n}: {cid} is not a case in the spec")
        if lane[cid] != want: die(f"{path}:{n}: {cid} is a {lane[cid]} case, wrong results file for the {want} lane")
        if cid in res: die(f"{path}:{n}: {cid} is reported twice")
        res[cid] = r
    if not res: die(f"{want} results file is empty -- nothing measured is not a pass")
    missing = sorted(k for k, v in lane.items() if v == want and k not in res)
    if missing: die(f"{want} lane has no result for {', '.join(missing)} -- unmeasured is not a pass")
    return res

vr, hr = load(os.environ["VIS"], "visible"), load(os.environ["HELD"], "held_out")
a, b = sum(v == "PASS" for v in vr.values()), len(vr)
c, dd = sum(v == "PASS" for v in hr.values()), len(hr)
gap_num = a * dd - c * b            # gap in cases = gap_num / b
blocker = gap_num > b or (a == b and c < dd)
print(f"acceptance-gap: visible {a}/{b} held_out {c}/{dd} gap={gap_num / b:.2f} verdict={'BLOCKER' if blocker else 'OK'}")
sys.exit(1 if blocker else 0)
PY
