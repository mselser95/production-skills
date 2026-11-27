#!/usr/bin/env bash
# lint.sh -- corpus lint. Hermetic: no agent, no network.
#
# WHY THIS EXISTS. A grader that always passes makes every skill look helpful; one
# that always fails makes every skill look useless; a prompt that names the skill
# leaks the arm into the "bare" run. None of those is visible in a success rate.
# So each task must show its grader RED on the unsolved fixture and GREEN on the
# reference solution, and each skill with tasks must keep a held-out task.
#
# task.json needs a non-empty string `kind`; a skill with _lib/output.schema.json needs a reference
# that writes a JSON object.
# Usage: lint.sh [--allow-empty] [corpus-root]    (default root: benchmarks/eval/corpus)
# Exit:  0 ok | 1 a check failed | 2 no task found (--allow-empty: 0, says it checked nothing)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/workdir.sh
source "$here/lib/workdir.sh"
allow_empty=0 root=""
for a in "$@"; do
  case "$a" in --allow-empty) allow_empty=1 ;; *) root="$a" ;; esac
done
root="${root:-$here/corpus}"
skills="prod-bootstrap prod-curate prod-implement prod-incident prod-new prod-ops prod-review prod-spec prod-test-synth"
fails=0 checked=0
fail() { printf '  FAIL  %-34s %s\n' "$1" "$2"; fails=$((fails + 1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-lint.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# validate_task_json <file> <dirname-skill> <dirname-id>  -> prints problems, one per line
validate() {
  python3 -I -B - "$1" "$2" "$3" "$skills" <<'PY'
import json, sys
f, dskill, did, skills = sys.argv[1:5]
try:
    t = json.load(open(f))
except Exception as e:
    print("task.json does not parse: %s" % e); sys.exit(0)
if not isinstance(t, dict):
    print("task.json is not an object"); sys.exit(0)
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
spec = {"id": lambda v: isinstance(v, str) and v, "skill": lambda v: isinstance(v, str) and v,
        "split": lambda v: v in ("dev", "heldout"), "prompt": lambda v: isinstance(v, str) and v.strip(),
        "timeout_s": lambda v: isinstance(v, int) and not isinstance(v, bool) and v > 0,
        "max_budget_usd": lambda v: num(v) and v > 0,
        "agent_mode": lambda v: v in ("read-only", "workspace-write"),
        "kind": lambda v: isinstance(v, str) and v.strip()}
for k, ok in spec.items():
    if k not in t: print("task.json missing key '%s'" % k)
    elif not ok(t[k]): print("task.json key '%s' has the wrong type/value" % k)
if t.get("skill") != dskill: print("skill '%s' != parent dir '%s'" % (t.get("skill"), dskill))
if dskill not in skills.split(): print("parent dir '%s' is not one of the nine skills" % dskill)
if t.get("id") != did: print("id '%s' != dir name '%s'" % (t.get("id"), did))
p = t.get("prompt")
if isinstance(p, str) and dskill.lower() in p.lower(): print("prompt names the skill '%s'" % dskill)
print("SPLIT=%s" % t.get("split"), file=sys.stderr)
PY
}

if [[ -d "$root" ]]; then
  for sdir in "$root"/*/; do
    [[ -d "$sdir" ]] || continue
    s="$(basename "$sdir")"; have_task=0 have_held=0
    case "$s" in _*|.*) continue ;; esac   # _lib etc.: shared corpus helpers, not a skill
    for tdir in "$sdir"*/; do
      [[ -f "$tdir/task.json" || -d "$tdir" ]] || continue
      tdir="${tdir%/}"; case "$(basename "$tdir")" in _*|.*) continue ;; esac
      t="$s/$(basename "$tdir")"; have_task=1; checked=$((checked + 1))
      probs="$(validate "$tdir/task.json" "$s" "$(basename "$tdir")" 2>"$tmp/split")"
      if [[ -n "$probs" ]]; then
        while IFS= read -r l; do fail "$t" "$l"; done <<<"$probs"
      fi
      grep -q '^SPLIT=heldout$' "$tmp/split" && have_held=1
      bad=0
      for x in grade.sh reference/solve.sh; do
        [[ -x "$tdir/$x" ]] || { fail "$t" "$x missing or not executable"; bad=1; }
      done
      [[ $bad -eq 0 ]] || continue
      # (a) RED on the unsolved fixture: empty agent output must FAIL the grader
      w="$tmp/a-work"; rm -rf "$w"; : >"$tmp/empty.txt"
      if ! eval_mkworkdir "$tdir" "$w"; then fail "$t" "fixture/setup could not build a workdir"; continue; fi
      (cd "$tmp" && bash "$tdir/grade.sh" "$w" "$tmp/empty.txt") >"$tmp/g.out" 2>/dev/null; rc=$?
      [[ $rc -eq 1 ]] || fail "$t" "grader exit $rc on the UNSOLVED fixture, want 1 (vacuous or broken grader)"
      # (b) GREEN on the reference solution
      w="$tmp/b-work"; rm -rf "$w"; : >"$tmp/ref.txt"
      eval_mkworkdir "$tdir" "$w" || { fail "$t" "fixture/setup could not build a workdir"; continue; }
      (cd "$w" && bash "$tdir/reference/solve.sh" "$w" "$tmp/ref.txt") >/dev/null 2>"$tmp/solve.err" \
        || { fail "$t" "reference/solve.sh failed"; continue; }
      if [[ -f "$sdir/_lib/output.schema.json" ]]; then   # the agent must answer under a schema: so must the reference
        python3 -I -B -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])),dict)' "$tmp/ref.txt" 2>/dev/null \
          || { fail "$t" "reference/solve.sh did not write a JSON object to the output file (the skill has $s/_lib/output.schema.json)"; continue; }
      fi
      (cd "$tmp" && bash "$tdir/grade.sh" "$w" "$tmp/ref.txt") >"$tmp/g.out" 2>/dev/null; rc=$?
      [[ $rc -eq 0 ]] || fail "$t" "grader exit $rc on the REFERENCE solution, want 0"
      tail -n 1 "$tmp/g.out" | python3 -I -B -c 'import json,sys; assert isinstance(json.loads(sys.stdin.read()),dict)' 2>/dev/null \
        || fail "$t" "grader did not print one JSON object line"
    done
    if [[ $have_task -eq 1 && $have_held -eq 0 ]]; then fail "$s" "no heldout task for this skill"; fi
  done
fi

if (( checked == 0 )); then
  if (( allow_empty )); then echo "lint: ok -- 0 tasks under $root; checked nothing (--allow-empty)"; exit 0; fi
  echo "lint: FAIL -- no task found under $root; nothing checked is not a pass" >&2; exit 2
fi
if (( fails )); then echo "lint: $fails failure(s) across $checked task(s)" >&2; exit 1; fi
echo "lint: ok -- $checked task(s): schema, no skill leak, grader RED on unsolved + GREEN on reference, heldout present"
