#!/usr/bin/env bash
# token-report-selftest.sh — fixture transcripts with KNOWN numbers; the report
# must reproduce them, detect the loop, honour the baseline, and refuse empty.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$here/../token-report.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; fail=0
check() { # desc, condition-exit
  n=$((n+1)); if [[ "$2" == 0 ]]; then :; else echo "FAIL: $1" >&2; fail=$((fail+1)); fi
}

R="$T/root"; D="$R/projects/p/subagents"; mkdir -p "$D"
python3 - "$D" <<'PY'
import json, sys
d = sys.argv[1]
def usage(i, r, c, o): return {"input_tokens": i, "cache_read_input_tokens": r, "cache_creation_input_tokens": c, "output_tokens": o}
def asst(u, content, model="m1"): return {"type": "assistant", "message": {"model": model, "usage": u, "content": content}}
def use(id_, name, inp): return {"type": "tool_use", "id": id_, "name": name, "input": inp}
def res(id_, text): return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id_, "content": text}]}}
def txt(t): return {"type": "text", "text": t}
def hb(id_, m): return use(id_, "SubagentHandback", {"message": m})
def write(name, agent, entries, raw=()):
    open(f"{d}/{name}.meta.json", "w").write(json.dumps({"agentType": agent}))
    open(f"{d}/{name}.jsonl", "w").write("\n".join(list(raw) + [json.dumps(e) for e in entries]) + "\n")
# a: IMPLEMENTED by text, 2 turns, input-side 100+300, maxctx 300, cat read 4 bytes
write("a", "impl", [
  asst(usage(10, 50, 40, 5), [use("t1", "Bash", {"command": "cat f"})]), res("t1", "okok"),
  asst(usage(20, 200, 80, 7), [txt("IMPLEMENTED done")])])
# b: BAIL, 3 turns, `make x` thrice, input-side 60 each = 180, maxctx 60, results 6 bytes
write("b", "impl", [
  asst(usage(10, 30, 20, 1), [use("t1", "Bash", {"command": "make x"})]), res("t1", "ee"),
  asst(usage(10, 30, 20, 1), [use("t2", "Bash", {"command": "make x"})]), res("t2", "ee"),
  asst(usage(10, 30, 20, 1), [use("t3", "Bash", {"command": "make x"}), txt("BAIL stuck")]), res("t3", "ee")])
# c: huge tool_result via Read, neither; 3 <synthetic> turns + 2 m1 turns -> model m1
write("c", "other", [
  asst(usage(5, 5, 5, 1), [use("t1", "Read", {"file_path": "/x"})]), res("t1", "z" * 100000),
  asst(usage(5, 5, 5, 1), [txt("finished")])] +
  [asst(usage(0, 0, 0, 0), [], "<synthetic>")] * 3)
# d: IMPLEMENTED via SubagentHandback only (last text says nothing), input-side 100
write("d", "hb", [asst(usage(50, 25, 25, 1), [hb("h", "IMPLEMENTED\nall good")])])
# e: TWO handbacks (IMPLEMENTED then AUTHORED) = two completions, input-side 20+20
write("e", "hb", [asst(usage(10, 5, 5, 1), [hb("h1", "IMPLEMENTED x")]),
                  asst(usage(10, 5, 5, 1), [hb("h2", "  AUTHORED y")])])
# f: "NOT IMPLEMENTED yet" is NOT a completion; also carries a non-object JSON line
write("f", "hb", [asst(usage(30, 15, 15, 1), [hb("h", "NOT IMPLEMENTED yet")])], raw=["[1,2]", "42"])
# g: whitespace-variant commands are ONE command run 3x -> a loop
write("g", "ws", [
  asst(usage(1, 1, 1, 1), [use("t1", "Bash", {"command": "make x"})]), res("t1", "r"),
  asst(usage(1, 1, 1, 1), [use("t2", "Bash", {"command": "make  x"})]), res("t2", "r"),
  asst(usage(1, 1, 1, 1), [use("t3", "Bash", {"command": " make x "}), txt("finished")]), res("t3", "r")])
# z: zero usage entries -> must not appear as a 0-turn row
write("z", "zero", [{"type": "assistant", "message": {"content": [txt("hi")]}}])
PY

out="$(BASELINE="$T/base.md" bash "$REPORT" "$R" 2>&1)"; rc=$?
check "report exits 0 with no baseline" "$rc"
grep -qE '^\| impl \| m1 \| 2 \| 2\.5 \| 595 \| 180 \| 5 \| 2 \| 50% \| 50% \| 580 \|$' <<<"$out"; check "impl: turns 2.5, mean max ctx 180, result bytes 5, read bytes 2, BAIL 50%, loop 50%, tokens/completed 580" $?
grep -qE '^\| other \| m1 \| 1 \| 5\.0 \| .*\| 100000 \| 100000 \| 0% \| 0% \| n/a \|$' <<<"$out"; check "other: synthetic ignored for model, no completion -> n/a, read bytes 100000" $?
grep -qE '^\| hb \| m1 \| 3 \| 1\.3 \| .*\| 0% \| 0% \| 67 \|$' <<<"$out"; check "hb: 3 handback completions over 200 tokens (NOT IMPLEMENTED is neither, [1,2] skipped) -> 67" $?
grep -qE '^\| ws \| m1 .*\| 100% \| n/a \|$' <<<"$out"; check "whitespace-variant commands count as one looping command" $?
grep -q '^| zero ' <<<"$out"; rc=$?; [[ "$rc" != 0 ]] && rc=0 || rc=1; check "zero-usage transcript makes no row" "$rc"
grep -qE 'mean max ctx' <<<"$out"; check "table header present" $?

BASELINE="$T/base.md" bash "$REPORT" --write "$R" >/dev/null 2>&1; rc=$?
check "--write exits 0" "$rc"
grep -q 'TREND' "$T/base.md"; check "baseline explains it is a TREND" $?
grep -qF "$T" "$T/base.md"; rc=$?; [[ "$rc" != 0 ]] && rc=0 || rc=1; check "baseline embeds no absolute path" "$rc"
BASELINE="$T/base.md" bash "$REPORT" "$R" >/dev/null 2>&1; rc=$?
check "re-run against own baseline passes" "$rc"

cp "$T/base.md" "$T/good.md"
# a baseline whose number is far LOWER than reality makes today's figure a >25% rise
sed -i.bak 's/^\(| impl .*\)| 580 |$/\1| 100 |/' "$T/base.md"
BASELINE="$T/base.md" bash "$REPORT" "$R" >/dev/null 2>"$T/err"; rc=$?
[[ "$rc" == 1 ]] && rc=0 || rc=1; check "inflated rise exits 1" "$rc"
grep -q 'ROSE  impl / m1' "$T/err"; check "names the group that rose" $?
# a baseline far HIGHER is a fall: free
sed -i.bak 's/^\(| impl .*\)| 100 |$/\1| 99999 |/' "$T/base.md"
BASELINE="$T/base.md" bash "$REPORT" "$R" >/dev/null 2>&1; rc=$?
check "a fall is not an alarm" "$rc"
# numeric in the baseline, n/a today -> alarm
cp "$T/good.md" "$T/base.md"; sed -i.bak 's/^\(| ws .*\)| n\/a |$/\1| 50 |/' "$T/base.md"
BASELINE="$T/base.md" bash "$REPORT" "$R" >/dev/null 2>"$T/err"; rc=$?
[[ "$rc" == 1 ]] && grep -q 'NA    ws / m1' "$T/err"; rc=$?; check "number -> n/a alarms" "$rc"
# a pair in the baseline and absent today -> alarm
cp "$T/good.md" "$T/base.md"; echo '| ghost | m1 | 1 | 1.0 | 1 | 1 | 0 | 0 | 0% | 0% | 10 |' >> "$T/base.md"
BASELINE="$T/base.md" bash "$REPORT" "$R" >/dev/null 2>"$T/err"; rc=$?
[[ "$rc" == 1 ]] && grep -q 'GONE  ghost / m1' "$T/err"; rc=$?; check "vanished pair alarms" "$rc"

mkdir -p "$T/empty"
BASELINE="$T/base.md" bash "$REPORT" "$T/empty" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && rc=0 || rc=1; check "empty root exits 2" "$rc"

# relative root case: cd to parent and use ./<name> as root
REL_PARENT="$T/rel_parent"; mkdir -p "$REL_PARENT"
REL_ROOT="fixture"; mkdir -p "$REL_PARENT/$REL_ROOT/projects/p/subagents"
python3 - "$REL_PARENT/$REL_ROOT/projects/p/subagents" <<'REL_PY'
import json, sys
d = sys.argv[1]
def usage(i, r, c, o): return {"input_tokens": i, "cache_read_input_tokens": r, "cache_creation_input_tokens": c, "output_tokens": o}
def asst(u, content, model="m1"): return {"type": "assistant", "message": {"model": model, "usage": u, "content": content}}
def txt(t): return {"type": "text", "text": t}
open(f"{d}/rel.meta.json", "w").write(json.dumps({"agentType": "relative"}))
open(f"{d}/rel.jsonl", "w").write(json.dumps(asst(usage(50, 25, 25, 1), [txt("IMPLEMENTED via relative")])) + "\n")
REL_PY
(cd "$REL_PARENT" && BASELINE="$(mktemp)" bash "$REPORT" "./$REL_ROOT" >/dev/null 2>&1); rc=$?
check "relative root resolves correctly from parent dir" "$rc"

# relative BASELINE with --write lands in the caller's cwd
(cd "$REL_PARENT" && BASELINE=./rel.md bash "$REPORT" --write "$REL_PARENT/$REL_ROOT" >/dev/null 2>&1); rc=$?
[[ "$rc" == 0 && -f "$REL_PARENT/rel.md" ]] && rc=0 || rc=1
check "relative BASELINE --write writes into the caller's dir" "$rc"

# default BASELINE from another cwd is the repo's benchmarks/ file, not /token-baseline.md
out="$(cd /tmp && env -u BASELINE bash "$REPORT" "$REL_PARENT/$REL_ROOT" 2>&1)"; rc=$?
grep -q 'benchmarks/token-baseline.md' <<<"$out" && ! grep -qE '(^| )/token-baseline.md' <<<"$out"; grc=$?
check "default BASELINE from another cwd names benchmarks/token-baseline.md, rc 0" "$(( rc + grc ))"

if (( fail )); then echo "token-report selftest: $fail FAILED of $n case(s)" >&2; exit 1; fi
echo "token-report selftest: ok -- $n case(s)"
