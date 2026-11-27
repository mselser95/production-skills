#!/usr/bin/env bash
# selftest.sh -- the harness proves itself, hermetically (no network, no model,
# < 60 s). Every guarded property is shown RED on a fixture where it is false
# and GREEN where it holds; a gate that cannot go red is not a gate.
#
# Exit: 0 every case passed | 1 a case failed | 2 no case ran
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 total=0
note() { # name ok(0/1) detail
  total=$((total + 1))
  if [[ "$2" -eq 0 ]]; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else printf '  FAIL  %s -- %s\n' "$1" "$3"; fi
}
# Platform-guarded cases. Seatbelt (sandbox-exec) and the macOS keychain CLI (security) exist on
# Darwin only; a case that needs one is guarded with `darwin_only <id>`, which on any other
# platform prints `SKIP <id> (darwin-only)` and returns 1. The ONE declaration of which cases
# those are is the next line; the accounting at the bottom fails on any drift, on either platform.
DARWIN_ONLY_DECLARED="14q2 14r 14s 14s2 14t 14u 14u2 14v 15a 15b 15i 15n 15o 15p 15q 15r 15s 15t 15u 15v 15w 15x 15y"
PLATFORM="$(uname)"; DO_SEEN="" DO_SKIPPED=""
darwin_only() {
  DO_SEEN="$DO_SEEN $1"
  [[ "$PLATFORM" == Darwin ]] && return 0
  DO_SKIPPED="$DO_SKIPPED $1"; printf '  SKIP  %s (darwin-only)\n' "$1"; return 1
}
# On a platform with no seatbelt the claude adapter refuses an unconfined run (exit 79); every case
# that is not ABOUT the sandbox opts out explicitly, as a user would, and asserts the row says so.
nosb_default=(); [[ "$PLATFORM" == Darwin ]] || nosb_default=(EVAL_CLAUDE_NO_SANDBOX=1)
want_sandbox=seatbelt; [[ "$PLATFORM" == Darwin ]] || want_sandbox=off
rowval() { python3 -I -B -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
v=rows[int(sys.argv[3])].get(sys.argv[2],"<absent>")
print(str(v).lower() if isinstance(v,bool) else v)' "$1" "$2" "${3:--1}"; }
section() { awk -v s="--$2--" '/^--.*--$/ {on = ($0 == s); next} on' "$1"; }   # body of one stub-record section
nrows() { grep -c . "$1" 2>/dev/null || echo 0; }

# ---- fixtures ---------------------------------------------------------------
# mktask <root> <skill> <id> <split> <grader: good|always0|always1|jsonobj> [prompt]
#   TASK_KIND=<kind> (default seeded) is written as task.json "kind".
#   jsonobj: passes iff the agent output file is a JSON object with found==1; its reference writes
#   {"found":1} (or $REF_OUT) to the output file instead of touching done.txt.
mktask() {
  local d="$1/$2/$3"; mkdir -p "$d/fixture" "$d/reference"
  printf '{"id":"%s","skill":"%s","split":"%s","kind":"%s","prompt":"%s","timeout_s":%s,"max_budget_usd":0.5,"agent_mode":"read-only"}\n' \
    "$3" "$2" "$4" "${TASK_KIND:-seeded}" "${6:-Create done.txt in the repo.}" "${TASK_TIMEOUT:-20}" >"$d/task.json"
  echo "fixture file" >"$d/fixture/README.md"
  case "$5" in
    good) printf '#!/usr/bin/env bash\nif [ -f "$1/done.txt" ]; then echo "{\\"found\\":1,\\"false_positives\\":0}"; exit 0; fi\necho "{\\"found\\":0,\\"false_positives\\":0}"; exit 1\n' >"$d/grade.sh" ;;
    always0) printf '#!/usr/bin/env bash\necho "{\\"found\\":1}"; exit 0\n' >"$d/grade.sh" ;;
    always1) printf '#!/usr/bin/env bash\necho "{\\"found\\":0}"; exit 1\n' >"$d/grade.sh" ;;
    jsonobj) cat >"$d/grade.sh" <<'GRADER'
#!/usr/bin/env bash
if python3 -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d,dict) and d.get("found")==1 else 1)' "$2" 2>/dev/null; then
  echo '{"found":1,"false_positives":0}'; exit 0
fi
echo '{"found":0,"false_positives":0}'; exit 1
GRADER
    ;;
  esac
  if [[ "$5" == jsonobj ]]; then
    local refout='{"found":1}'; [[ -n "${REF_OUT:-}" ]] && refout="$REF_OUT"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >"$2"\n' "$refout" >"$d/reference/solve.sh"
  else
    printf '#!/usr/bin/env bash\ntouch "$1/done.txt"\n' >"$d/reference/solve.sh"
  fi
  chmod +x "$d/grade.sh" "$d/reference/solve.sh"
  echo "$d"
}
corpus="$tmp/corpus"; good="$(mktask "$corpus" prod-review t-good heldout good)"
# a skills root whose references/ is a SYMLINK, as in the real repo
skills="$tmp/skills"; mkdir -p "$skills/prod-review" "$tmp/shared"
echo "---
name: prod-review
---" >"$skills/prod-review/SKILL.md"; echo "shared reference text" >"$tmp/shared/ref.md"
ln -s ../../shared "$skills/prod-review/references"

# cell <results> <task> <arm> <mode> [extra env assignments...]
cell() {
  local res="$1" task="$2" arm="$3" mode="$4"; shift 4
  env STUB_MODE="$mode" STUB_SOLVE_CMD="$task/reference/solve.sh" EVAL_SKILLS_ROOT="$skills" "$@" \
    bash "$here/run.sh" --task "$task" --arm "$arm" --host stub --rep 1 --out "$res" >/dev/null 2>&1
}

# ---- 1-4: the stub through the runner ----------------------------------------
r="$tmp/r1.jsonl"; cell "$r" "$good" skill solve
ok=1; [[ "$(rowval "$r" pass)" == true && "$(rowval "$r" tokens_in)" == 1200 && "$(rowval "$r" cost_usd)" == 0.01 && "$(rowval "$r" exit)" == 0 ]] && ok=0
note "1 stub solve -> pass:true, usage carried" $ok "row: $(cat "$r" 2>&1 | cut -c1-300)"
python3 -I -B - "$r" <<'PY' && ok=0 || ok=1
import json, sys
need = "task skill split arm host model rep pass metrics tokens_in tokens_out cost_usd duration_s exit timed_out skill_sha harness_sha ts".split()
r = json.loads(open(sys.argv[1]).readline())
sys.exit(0 if all(k in r for k in need) and r["metrics"].get("found") == 1 else 1)
PY
note "1b row carries every contract key + grader metrics" $ok "missing keys in $(cat "$r" | cut -c1-200)"

r="$tmp/r2.jsonl"; cell "$r" "$good" skill noop
ok=1; [[ "$(rowval "$r" pass)" == false && "$(rowval "$r" exit)" == 0 ]] && ok=0
note "2 stub noop -> pass:false" $ok "row: $(cat "$r" 2>&1 | cut -c1-300)"

r="$tmp/r3.jsonl"; secs=$((4000 + RANDOM % 900)); tt="$(TASK_TIMEOUT=2 mktask "$corpus" prod-review t-slow dev good)"
cell "$r" "$tt" skill timeout STUB_CHILD_SECS="$secs"
sleep 0.5
ok=1; [[ "$(nrows "$r")" == 1 && "$(rowval "$r" timed_out)" == true && "$(rowval "$r" pass)" == false ]] && ok=0
note "3 stub timeout -> row, timed_out:true, pass:false" $ok "row: $(cat "$r" 2>&1 | cut -c1-300)"
stray="$(pgrep -f "sleep $secs" || true)"
if [[ -z "$stray" ]]; then r=0; else r=1; fi; note "3b no stray child survives the timeout" "$r" "pid(s) still alive: $stray"
[[ -n "$stray" ]] && kill $stray 2>/dev/null

r="$tmp/r4.jsonl"; cell "$r" "$good" skill crash
ok=1; [[ "$(nrows "$r")" == 1 && "$(rowval "$r" pass)" == false && "$(rowval "$r" error)" == *"host exit 3"* ]] && ok=0
note "4 stub crash -> row with error" $ok "row: $(cat "$r" 2>&1 | cut -c1-300)"

# ---- 5-6: isolation ----------------------------------------------------------
rec="$tmp/rec-skill.txt"; cell "$tmp/r5.jsonl" "$good" skill solve STUB_RECORD="$rec"
ok=1; grep -q '^\./skills/prod-review/SKILL.md$' "$rec" && grep -q '^\./skills/prod-review/references/ref.md$' "$rec" \
  && [[ -z "$(section "$rec" home-symlinks)" ]] && ok=0
note "5a arm skill: SKILL.md in isolated home, symlinked reference dereferenced" $ok "record: $(grep -c . "$rec") lines; symlinks: $(section "$rec" home-symlinks | tr '\n' ' ')"
ok=1; grep -qx 'Use the prod-review skill for this.' "$rec" && ok=0
note "5a2 arm skill: prompt gets the one-line suffix" $ok "prompt tail: $(tail -n 3 "$rec")"
rec="$tmp/rec-bare.txt"; cell "$tmp/r5b.jsonl" "$good" bare solve STUB_RECORD="$rec"
ok=1; ! grep -q 'SKILL.md\|skills' "$rec" && ! grep -q 'Use the .* skill' "$rec" && ok=0
note "5b arm bare: nothing installed, prompt unchanged" $ok "record: $(grep -n 'skill' "$rec" | head -3)"

wl="$(section "$rec" workdir)"   # captured, then matched (no early-exit grep on a pipe under pipefail)
ok=1; [[ "$wl" == *README.md* && "$wl" != *grade.sh* && "$wl" != *reference* && "$wl" != *task.json* && "$wl" != *solve.sh* ]] && ok=0
note "6 grade.sh / reference / task.json never in the agent's workdir" $ok "workdir listing: $(echo "$wl" | tr '\n' ' ')"

# ---- 7: lint goes red where it must ------------------------------------------
lint_case() { # name root want_rc want_substring
  local out rc; out="$(bash "$here/lint.sh" "$2" 2>&1)"; rc=$?
  if [[ $rc -eq $3 && "$out" == *"$4"* ]]; then r=0; else r=1; fi; note "$1" "$r" "rc=$rc want=$3, wanted '$4' in: $(echo "$out" | tail -n 4 | tr '\n' ' ')"
}
mktask "$tmp/l-good" prod-review t-good heldout good >/dev/null
lint_case "7a lint GREEN on a good task" "$tmp/l-good" 0 "lint: ok"
mktask "$tmp/l-vac" prod-review t-vac heldout always0 >/dev/null
lint_case "7b lint RED on a vacuous grader (always exit 0)" "$tmp/l-vac" 1 "UNSOLVED fixture"
mktask "$tmp/l-never" prod-review t-never heldout always1 >/dev/null
lint_case "7c lint RED on a grader that always exits 1" "$tmp/l-never" 1 "REFERENCE solution"
mktask "$tmp/l-leak" prod-review t-leak heldout good "Please run prod-review on this repo." >/dev/null
lint_case "7d lint RED on a prompt naming the skill" "$tmp/l-leak" 1 "prompt names the skill"
mktask "$tmp/l-nohold" prod-review t-dev dev good >/dev/null
lint_case "7e lint RED on a skill with no heldout task" "$tmp/l-nohold" 1 "no heldout task"
mkdir -p "$tmp/l-empty"
lint_case "7f lint exit 2 on an empty corpus, 0 with --allow-empty" "$tmp/l-empty" 2 "nothing checked"
out="$(bash "$here/lint.sh" --allow-empty "$tmp/l-empty" 2>&1)"; rc7=$?; if [[ $rc7 -eq 0 && "$out" == *"checked nothing"* ]]; then r=0; else r=1; fi; note "7g --allow-empty says it checked nothing" "$r" "$out"

# ---- 8: report -----------------------------------------------------------------
mkrep() { # mkrep <file> : synthetic rows, 10 tasks x 2 reps per arm
python3 -I -B - "$1" <<'PY'
import json, sys
rows = []
def add(skill, split, arm, tid, rep, ok, model="m1"):
    rows.append({"task": tid, "skill": skill, "split": split, "kind": "seeded", "arm": arm, "host": "claude", "model": model, "rep": rep, "pass": ok,
                 "metrics": {"false_positives": 0 if ok else 1}, "tokens_in": 1000 if ok else 3000,
                 "tokens_out": 200 if ok else 600, "duration_s": 5.0 if ok else 15.0})
for t in range(10):
    for rep in (1, 2):
        add("prod-review", "heldout", "skill", "t%d" % t, rep, True)            # helps: 20/20 vs 4/20
        add("prod-review", "heldout", "bare", "t%d" % t, rep, t < 2)
        add("prod-spec", "heldout", "skill", "t%d" % t, rep, t < 1)             # hurts: 2/20 vs 20/20
        add("prod-spec", "heldout", "bare", "t%d" % t, rep, True)
        add("prod-ops", "heldout", "skill", "t%d" % t, rep, rep == 1)           # no evidence; rate 10/20 but pass^k 0.00
        add("prod-ops", "heldout", "bare", "t%d" % t, rep, rep == 1 and t < 9)
for arm in ("skill", "bare"):
    for rep in (1, 2):
        add("prod-review", "dev", arm, "d0", rep, False)
        add("prod-review", "heldout", arm, "x0", rep, arm == "skill", model="m2")   # a second model: its own rows
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}
syn="$tmp/syn.jsonl"; mkrep "$syn"
rep="$(python3 -I -B "$here/report.py" "$syn" 2>&1)"
line() { echo "$rep" | grep -E "$1" || true; }
l="$(line '^prod-review +claude +m1 +n/a +heldout +seeded +skill ')"
if [[ "$l" == *"100.0% (20/20)"* && "$l" == *"1.00 (k=2)"* ]]; then r=0; else r=1; fi
note "8a report: exact rate and pass^k with k printed (skill arm)" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +heldout +seeded +bare ')"
if [[ "$l" == *"20.0% (4/20)"* && "$l" == *"0.20 (k=2)"* && "$l" =~ [[:space:]]0\.80[[:space:]]+n/a$ ]]; then r=0; else r=1; fi
note "8b report: bare arm 4/20, pass^k 0.20, false_pos mean per row 0.80 (16 over 20 rows)" "$r" "$l"
# cost = ALL spend / passing rows: bare spent 4*1200 + 16*3600 = 62400 tok over 4 resolved = 15600; 4*5+16*15=260 s / 4 = 65.0
if [[ "$l" == *" 15600 "* && "$l" == *" 65.0 "* ]]; then r=0; else r=1; fi
note "8c cost per resolved = total spend over all rows / passing rows" "$r" "$l"
l="$(line '^prod-ops +claude +m1 +n/a +heldout +seeded +bare ')"
if [[ "$l" == *"0.00 (k=2)"* && "$l" == *"45.0% (9/20)"* ]]; then r=0; else r=1; fi
note "8d pass^k is share of tasks with ALL reps passing, not k/n" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +heldout +seeded +\+')"
if [[ "$l" == *"+80.0 pp"* && "$l" == *helps ]]; then r=0; else r=1; fi
note "8e verdict: clear helps (task-clustered bootstrap)" "$r" "$l"
l="$(line '^prod-spec +claude +m1 +n/a +heldout +seeded +-')"
if [[ "$l" == *"-90.0 pp"* && "$l" == *hurts ]]; then r=0; else r=1; fi
note "8f verdict: clear hurts" "$r" "$l"
l="$(line '^prod-ops +claude +m1 +n/a +heldout +seeded +[-+]')"
if [[ "$l" == *"+5.0 pp"* && "$l" == *"no evidence" ]]; then r=0; else r=1; fi
note "8g verdict: no evidence" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +dev +seeded +skill ')"
if [[ "$l" == *"0.0% (0/2)"* ]]; then r=0; else r=1; fi
note "8h dev and heldout are separate rows (never pooled)" "$r" "$l"
l="$(line '^prod-review +claude +m2 +n/a +heldout +seeded +skill ')"; l2="$(line '^prod-review +claude +m2 +n/a +heldout +seeded +[-+]')"
if [[ "$l" == *"100.0% (2/2)"* && "$l2" == *"insufficient tasks (n=1)"* ]]; then r=0; else r=1; fi
note "8i models are never pooled; too few paired tasks -> insufficient tasks" "$r" "$l / $l2"
python3 -I -B "$here/report.py" "$syn" >"$tmp/rep.a" 2>&1; python3 -I -B "$here/report.py" "$syn" >"$tmp/rep.b" 2>&1
cmp -s "$tmp/rep.a" "$tmp/rep.b"; r=$?
note "8j same seed twice -> identical report" "$r" "reports differ"
: >"$tmp/empty.jsonl"; python3 -I -B "$here/report.py" "$tmp/empty.jsonl" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then r=0; else r=1; fi
note "8k report exits 2 on a file with no rows" "$r" "exit was $rc"
{ head -n 3 "$syn"; echo '{"truncated":'; } >"$tmp/bad.jsonl"
msg="$(python3 -I -B "$here/report.py" "$tmp/bad.jsonl" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -eq 1 && "$msg" == *"bad.jsonl:4:"* ]]; then r=0; else r=1; fi
note "8l a non-JSON line is an error with file:line, never dropped" "$r" "rc=$rc $msg"
# uneven reps across arms -> a visible WARNING
{ grep '"skill": "prod-review"' "$syn" | grep '"split": "heldout"' | grep '"model": "m1"' | grep -v '"rep": 2'; } >"$tmp/uneven.jsonl"
out="$(python3 -I -B "$here/report.py" "$tmp/uneven.jsonl" 2>&1)"
if [[ "$out" == *"k=1"* ]]; then r=0; else r=1; fi
note "8m pass^k prints k (k=1 when one rep per task)" "$r" "$(echo "$out" | head -4 | tr '\n' ' ')"
python3 -I -B - "$tmp/uneven2.jsonl" <<'PY'
import json, sys
rows = []
for arm in ("skill", "bare"):
    for t in range(6):
        for rep in range(2 if arm == "skill" else 3):
            rows.append({"task": "t%d" % t, "skill": "prod-ops", "split": "dev", "kind": "seeded", "arm": arm, "host": "codex", "model": None, "rep": rep, "pass": True, "metrics": {}})
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
PY
out="$(python3 -I -B "$here/report.py" "$tmp/uneven2.jsonl" 2>&1)"
if [[ "$out" == *"WARNING"*"not comparable on pass^k (k=2 skill vs k=3 bare)"* ]]; then r=0; else r=1; fi
note "8n unequal reps across arms -> visible pass^k WARNING" "$r" "$(echo "$out" | tail -3 | tr '\n' ' ')"
# T3: Wilson interval exact (the z^2/4n^2 term matters at small n)
w="$(python3 -I -B - "$here" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import report
a = report.wilson(7, 10); b = report.wilson(0, 5)
print("%.1f %.1f %.1f %.1f" % (100*a[1], 100*a[2], 100*b[1], 100*b[2]))
PY
)"
if [[ "$w" == "39.7 89.2 0.0 43.4" ]]; then r=0; else r=1; fi
note "8o Wilson interval exact: 7/10 -> [39.7, 89.2], 0/5 -> [0.0, 43.4]" "$r" "got: $w"
# T7: clustered paired verdicts on 6 / 3 tasks
mkpair() { # mkpair <file> <skill-pass-list> <bare-pass-list>   e.g. "1 1 1 1 1 1"
python3 -I -B - "$1" "$2" "$3" <<'PY'
import json, sys
f, sk, ba = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
with open(f, "w") as o:
    for arm, v in (("skill", sk), ("bare", ba)):
        for t, x in enumerate(v):
            for rep in (1, 2):
                o.write(json.dumps({"task": "t%d" % t, "skill": "prod-spec", "split": "heldout", "kind": "seeded", "arm": arm, "host": "claude", "model": "m", "rep": rep, "pass": x == "1", "metrics": {}}) + "\n")
PY
}
vline() { python3 -I -B "$here/report.py" "$1" 2>&1 | grep -E '^prod-spec +claude +m +n/a +heldout +seeded +[-+n]' || true; }
mkpair "$tmp/p1.jsonl" "1 1 1 1 1 1" "0 0 0 0 0 0"; l="$(vline "$tmp/p1.jsonl")"
if [[ "$l" == *helps ]]; then r=0; else r=1; fi; note "8p 6 paired tasks, skill clearly wins -> helps" "$r" "$l"
mkpair "$tmp/p2.jsonl" "0 0 0 0 0 0" "1 1 1 1 1 1"; l="$(vline "$tmp/p2.jsonl")"
if [[ "$l" == *hurts ]]; then r=0; else r=1; fi; note "8q 6 paired tasks, skill clearly loses -> hurts" "$r" "$l"
mkpair "$tmp/p3.jsonl" "1 0 1 0 1 0" "0 1 0 1 1 0"; l="$(vline "$tmp/p3.jsonl")"
if [[ "$l" == *"no evidence" ]]; then r=0; else r=1; fi; note "8r 6 paired tasks, mixed -> no evidence" "$r" "$l"
mkpair "$tmp/p4.jsonl" "1 1 1" "0 0 0"; l="$(vline "$tmp/p4.jsonl")"
if [[ "$l" == *"+100.0 pp"* && "$l" == *"insufficient tasks (n=3)" ]]; then r=0; else r=1; fi
note "8s 3 paired tasks -> estimate printed, verdict insufficient tasks (n=3)" "$r" "$l"

# ---- 9-10: the real homes are never touched, temp dirs are cleaned -------------
fh="$tmp/fakehome"; ftmp="$tmp/faketmp"; mkdir -p "$fh" "$ftmp"
cell "$tmp/r9.jsonl" "$good" skill solve HOME="$fh" TMPDIR="$ftmp" CLAUDE_CONFIG_DIR="$fh/nope" CODEX_HOME="$fh/nope2"
if [[ "$(rowval "$tmp/r9.jsonl" pass)" == true && -z "$(find "$fh" -mindepth 1 | head -1)" ]]; then r=0; else r=1; fi; note "9 HOME left empty: nothing created under it by the stub path" "$r" "found: $(find "$fh" -mindepth 1 | head -3 | tr '\n' ' ')"
if [[ "$(rowval "$tmp/r9.jsonl" pass)" == true && -z "$(find "$ftmp" -mindepth 1 | head -1)" ]]; then r=0; else r=1; fi; note "10 temp dirs removed after the cell (EVAL_KEEP unset)" "$r" "left: $(find "$ftmp" -mindepth 1 | head -3 | tr '\n' ' ')"

# ---- 11-12: host output parsers -------------------------------------------------
echo '{"result":"OK","is_error":false,"total_cost_usd":0.0123,"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":7}}' >"$tmp/c.json"
python3 -I -B "$here/lib/parse_claude.py" "$tmp/c.json" "$tmp/c.out" "$tmp/c.usage"
if [[ "$(cat "$tmp/c.out")" == OK && "$(cat "$tmp/c.usage")" == *'"tokens_in": 1103'* && "$(cat "$tmp/c.usage")" == *'"cost_usd": 0.0123'* ]]; then r=0; else r=1; fi; note "11 claude parser: result text, tokens_in = input+cache_creation+cache_read, cost" "$r" "$(cat "$tmp/c.usage" 2>&1)"
printf '%s\n' '{"type":"thread.started"}' '{"type":"item.completed","item":{"type":"agent_message","text":"first"}}' \
  '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":4,"reasoning_output_tokens":2}}' >"$tmp/x.jsonl"
python3 -I -B "$here/lib/parse_codex.py" "$tmp/x.jsonl" "$tmp/x.out" "$tmp/x.usage"
if [[ "$(cat "$tmp/x.out")" == OK && "$(cat "$tmp/x.usage")" == *'"tokens_in": 50'* && "$(cat "$tmp/x.usage")" == *'"cost_usd": null'* ]]; then r=0; else r=1; fi; note "12 codex parser: last agent_message, usage from turn.completed, cost null" "$r" "$(cat "$tmp/x.usage" 2>&1)"

# ---- 13: runner semantics the validator found unguarded ----------------------------
# R1: the grader would PASS (the work was done) but the host crashed / hung: no credit.
r="$tmp/r13a.jsonl"; cell "$r" "$good" skill solve STUB_EXIT=3
if [[ "$(rowval "$r" pass)" == false && "$(rowval "$r" exit)" == 3 && "$(rowval "$r" metrics)" == *"'found': 1"* ]]; then ok=0; else ok=1; fi
note "13a host crashed AFTER solving (grader passes) -> pass:false" $ok "row: $(cut -c1-300 "$r" 2>&1)"
r="$tmp/r13b.jsonl"; cell "$r" "$tt" skill solve STUB_HANG=1
if [[ "$(rowval "$r" pass)" == false && "$(rowval "$r" timed_out)" == true && "$(rowval "$r" metrics)" == *"'found': 1"* ]]; then ok=0; else ok=1; fi
note "13b host hung AFTER solving (grader passes) -> pass:false, timed_out" $ok "row: $(cut -c1-300 "$r" 2>&1)"
# A1: no credential -> row error "auth" and run.sh exits 3 (a live loop stops)
r="$tmp/r13c.jsonl"; cell "$r" "$good" skill noauth; rc=$?
if [[ $rc -eq 3 && "$(rowval "$r" error)" == auth && "$(rowval "$r" pass)" == false ]]; then ok=0; else ok=1; fi
note "13c host without credential -> row error:auth, run.sh exit 3" $ok "rc=$rc row: $(cut -c1-300 "$r" 2>&1)"
# R2: TERM mid-cell kills the whole host process group and cleans the temp dirs
sigtmp="$tmp/sigtmp"; mkdir -p "$sigtmp"; ready="$tmp/ready"; secs=$((5000 + RANDOM % 900))
tt2="$(TASK_TIMEOUT=120 mktask "$corpus" prod-review t-sig dev good)"
env TMPDIR="$sigtmp" STUB_MODE=timeout STUB_CHILD_SECS="$secs" STUB_READY="$ready" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$tt2" --arm skill --host stub --rep 1 --out "$tmp/r13d.jsonl" >/dev/null 2>&1 &
rpid=$!
i=0; while [[ ! -e "$ready" && $i -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done   # bounded start-up wait, not a gate poll
kill -TERM "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null; rc=$?
sleep 0.3; stray="$(pgrep -f "sleep $secs" || true)"
if [[ $rc -eq 143 && -z "$stray" && -z "$(find "$sigtmp" -mindepth 1 | head -1)" ]]; then ok=0; else ok=1; fi
# shellcheck disable=SC2086
[[ -n "$stray" ]] && kill $stray 2>/dev/null
note "13d TERM on run.sh mid-cell: exit 143, no surviving host child, temp dirs gone" $ok "rc=$rc stray='$stray' left: $(find "$sigtmp" -mindepth 1 | head -2 | tr '\n' ' ')"
# R3: truthful sha fields
gr="$tmp/gitrepo"; mkdir -p "$gr/prod-review" "$gr/benchmarks/eval"; echo a >"$gr/prod-review/SKILL.md"
( cd "$gr" && git init -q . && git add prod-review && git -c user.name=t -c user.email=t@e.invalid commit -q -m c )
r="$tmp/r13e.jsonl"; cell "$r" "$good" bare noop EVAL_REPO_ROOT="$gr"
echo b >>"$gr/prod-review/SKILL.md"; cell "$r" "$good" bare noop EVAL_REPO_ROOT="$gr"
sha1="$(rowval "$r" skill_sha 0)"; sha2="$(rowval "$r" skill_sha 1)"; sh1="$(rowval "$r" harness_sha 0)"
if [[ "$sha1" =~ ^[0-9a-f]{4,}$ && "$sha2" == "$sha1+dirty" && "$sh1" == unknown ]]; then ok=0; else ok=1; fi
note "13e sha fields: <sha> clean, <sha>+dirty edited, unknown never committed" $ok "clean=$sha1 edited=$sha2 harness=$sh1"
# agent_mode is required
mktask "$tmp/l-nomode" prod-review t-nomode heldout good >/dev/null
python3 -I -B - "$tmp/l-nomode/prod-review/t-nomode/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); del t["agent_mode"]; json.dump(t, open(sys.argv[1], "w"))
PY
lint_case "13f lint RED on a task.json without agent_mode" "$tmp/l-nomode" 1 "missing key 'agent_mode'"
# C2: corpus helper selftests are discovered and a failing one fails
lt="$tmp/lt-ok"; mkdir -p "$lt/prod-review/_lib"; printf '#!/usr/bin/env bash\nexit 0\n' >"$lt/prod-review/_lib/g-selftest.sh"; chmod +x "$lt/prod-review/_lib/g-selftest.sh"
out="$(bash "$here/lib/libtests.sh" "$lt" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"ok -- 1 corpus helper"* ]]; then ok=0; else ok=1; fi
note "13g libtests runs a passing corpus _lib selftest" $ok "rc=$rc $out"
lt="$tmp/lt-bad"; mkdir -p "$lt/prod-review/_lib"; printf '#!/usr/bin/env bash\necho boom\nexit 1\n' >"$lt/prod-review/_lib/g-selftest.sh"; chmod +x "$lt/prod-review/_lib/g-selftest.sh"
out="$(bash "$here/lib/libtests.sh" "$lt" 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"FAIL"* ]]; then ok=0; else ok=1; fi
note "13h libtests FAILS when a corpus _lib selftest fails" $ok "rc=$rc $out"
mk_eval="$(awk '/^eval:/{f=1;next} /^[a-z]/{f=0} f' "$here/../../Makefile")"
if [[ "$mk_eval" == *lib/libtests.sh* && "$mk_eval" == *selftest.sh* && "$mk_eval" == *lint.sh* ]]; then ok=0; else ok=1; fi
note "13i make eval runs selftest, libtests and lint" $ok "recipe: $mk_eval"

# ---- 14: the real adapters against FAKE claude/codex binaries ------------------
# Nothing here touches the real ~/.claude*, ~/.codex or keychain: every home,
# auth dir and keychain command is injected and points under $tmp.
# frec (the fakes' record/canned-output dir) IS the fakes' own dir: a sandboxed fake binary can read only its own
# install root (default-deny reads), and the canned output a case leaves for it (claude.out) must be readable there:
# do NOT move it back under $tmp (15u proves a file there is unreadable to the fake, one in its install dir is readable).
fb="$tmp/fakebin"; frec="$fb"; mkdir -p "$fb" "$tmp/outside"
realhome="$tmp/callerhome"; realcodex="$tmp/realcodex"; realclaude="$tmp/realclaude"; mkdir -p "$realhome" "$realcodex" "$realclaude"
mkdir -p "$realhome/.ssh" "$realhome/.claude"; echo SSH-CANARY >"$realhome/.ssh/canary"; echo CFG-CANARY >"$realhome/.claude/canary"
corpusfile="$(find "$here/corpus" -name task.json | sort | head -1)"
cat >"$fb/claude" <<FAKE
#!/usr/bin/env bash
R="\$CLAUDE_CONFIG_DIR"   # the only place a sandboxed host may record into
printf '%s\n' "\$@" >"\$R/claude.argv"; env >"\$R/claude.env"; pwd -P >"\$R/claude.cwd"; cat >/dev/null
t() { if touch "\$2" 2>/dev/null; then echo "\$1=written"; else echo "\$1=denied"; fi; }
{ t outside "$tmp/outside/canary"; t home "\$R/canary"; t work "\$PWD/canary"; t gocache "\$GOCACHE/canary"; t tmp "\$TMPDIR/canary"; } >"\$R/claude.touch"
r() { if cat "\$2" >/dev/null 2>&1; then echo "\$1=read"; else echo "\$1=denied"; fi; }
{ r ssh "$realhome/.ssh/canary"; r claudecfg "$realhome/.claude/canary"; r taskdir "$good/grade.sh"; r corpus "$corpusfile"; r workfile "\$PWD/README.md"; } >"\$R/claude.read"
if [ -f "$frec/claude.out" ]; then cat "$frec/claude.out"; else
echo '{"result":"OK","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2}}'; fi
FAKE
cat >"$fb/codex" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$frec/codex.argv"; env >"$frec/codex.env"; pwd -P >"$frec/codex.cwd"
if [ -f "$frec/stdincheck" ]; then   # a host that waits on a stdin that never closes is a hung host: bound it
  if IFS= read -r -t 5 line; then printf '%s\n' "\$line" >"$frec/codex.stdin"; else echo HUNG >"$frec/codex.stdin"; fi
else cat >/dev/null; fi
lastf=""; prev=""; for a in "\$@"; do if [ "\$prev" = -o ]; then lastf="\$a"; fi; prev="\$a"; done
if [ -n "\$lastf" ] && [ -f "$frec/codex.last" ]; then cat "$frec/codex.last" >"\$lastf"; fi
if [ -f "\$CODEX_HOME/auth.json" ]; then echo yes >"$frec/codex.hadauth"; else echo no >"$frec/codex.hadauth"; fi
if [ -f "$frec/rotate" ]; then echo '{"canary":"ROTATED-CANARY"}' >"\$CODEX_HOME/auth.json"; fi
if [ -f "$frec/changereal" ]; then echo '{"canary":"OTHER-PROCESS-CANARY"}' >"$realcodex/auth.json"; fi
if [ -f "$frec/changesame" ]; then echo '{"canary":"ORIG-CANAXX"}' >"$realcodex/auth.json"; fi
if [ -f "$frec/codex.jsonl" ]; then cat "$frec/codex.jsonl"; else
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'; fi
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
FAKE
cat >"$fb/security" <<FAKE
#!/usr/bin/env bash
if [ -f "$frec/keychain" ]; then cat "$frec/keychain"; exit 0; fi
exit 44
FAKE
chmod +x "$fb/claude" "$fb/codex" "$fb/security"
echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"; chmod 600 "$realcodex/auth.json"
echo '{"claudeAiOauth":{"accessToken":"TRACE-CANARY-456","refreshToken":"REFRESH-CANARY"}}' >"$realclaude/.credentials.json"
an=0
# adapter <host> <mode> <env-assignments...> : fresh home+workdir, hostile caller env, fake CLIs first on PATH
adapter() {
  local h="$1" m="$2"; shift 2; an=$((an + 1))
  # ABASE=<dir> (default $tmp) puts the cell dirs elsewhere; AGIT=1 makes the workdir a git repo with one commit and one uncommitted edit
  local cxnosb=(); [[ "$h" == codex && -z "${CXSB:-}" ]] && cxnosb=(EVAL_NO_SANDBOX=1)   # CXSB=1 adapter codex ... keeps the sandbox ON
  local base="$tmp" gitw="" denyroots="" a rest=(); for a in "$@"; do case "$a" in ABASE=*) base="${a#ABASE=}" ;; AGIT=*) gitw="${a#AGIT=}" ;; DENYROOTS=*) denyroots="${a#DENYROOTS=}" ;; *) rest+=("$a") ;; esac; done
  set -- ${rest[@]+"${rest[@]}"}
  AH="$base/ahome$an"; AW="$base/awork$an"; AG="$base/agocache$an"; mkdir -p "$AH" "$AW" "$AG"; echo "do the thing" >"$tmp/ap.txt"; echo "workdir file" >"$AW/README.md"
  if [[ -n "$gitw" ]]; then ( cd "$AW" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q . && git add -A \
    && git -c user.name=e -c user.email=e@e.invalid -c commit.gpgsign=false commit -q -m i && echo more >>README.md ) >/dev/null 2>&1; fi
  rm -f "${frec:?}/codex.argv" "${frec:?}/codex.env" "${frec:?}/codex.cwd" "${frec:?}/codex.hadauth" "${frec:?}/codex.stdin"
  ( cd "$tmp" && env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CODEX_API_KEY \
      ${nosb_default[@]+"${nosb_default[@]}"} ${cxnosb[@]+"${cxnosb[@]}"} PATH="$fb:$PATH" HOME="$realhome" OLDPWD=/some/repo CLAUDECODE=1 CLAUDE_EFFORT=high CLAUDE_CODE_SESSION_ID=sess-x \
      CLAUDE_CODE_MESSAGING_TOKEN=msgtok CLAUDE_CODE_CHILD_SESSION=1 EVAL_CANARY=canary-var \
      EVAL_GOCACHE="$AG" EVAL_CODEX_REAL_HOME="$realcodex" EVAL_CLAUDE_AUTH_DIR="$realclaude" \
      "$@" \
      bash ${ADAPTER_SH_FLAGS:-} "$here/hosts/$h.sh" "$AW" "$AH" "$tmp/ap.txt" "$tmp/aout.txt" "$tmp/ausage.json" "" 0.5 "$m" "${ADAPTER_SCHEMA:-}" ${denyroots:+--deny-roots "$denyroots"} ) >"$tmp/adapter.out" 2>"$tmp/adapter.err"
  return $?
}
argafter() { awk -v f="$2" 'p {print; exit} $0 == f {p=1}' "$1"; }   # the argv line following a flag
envhas() { grep -q "^$2=" "$1"; }                                      # $1 = recorded env file

for h in claude codex; do
  cfgvar=CLAUDE_CONFIG_DIR; [[ $h == codex ]] && cfgvar=CODEX_HOME
  adapter $h read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 CODEX_API_KEY=k; arc=$?
  ev="$frec/$h.env"; cwdf="$frec/$h.cwd"; if [[ $h == claude ]]; then ev="$AH/claude.env"; cwdf="$AH/claude.cwd"; fi; leak=""
  for v in CLAUDECODE CLAUDE_EFFORT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_CHILD_SESSION OLDPWD EVAL_CANARY EVAL_GOCACHE EVAL_CODEX_REAL_HOME EVAL_CLAUDE_AUTH_DIR; do
    if envhas "$ev" "$v"; then leak="$leak $v"; fi
  done
  if [[ $arc -eq 0 && -z "$leak" ]]; then ok=0; else ok=1; fi
  note "14a/$h the host does not inherit the caller's environment" $ok "rc=$arc leaked:$leak err: $(head -c 200 "$tmp/adapter.err")"
  if grep -qx "HOME=$AH" "$ev" && grep -qx "$cfgvar=$AH" "$ev" && ! grep -q "$realhome" "$ev" \
     && grep -qx "GOPROXY=off" "$ev" && grep -qx "GOTOOLCHAIN=local" "$ev" && grep -qx "GOCACHE=$AG" "$ev"; then ok=0; else ok=1; fi
  if [[ $h == claude ]] && ! grep -qx "CLAUDE_CODE_TMPDIR=$AH/tmp" "$ev"; then ok=1; fi
  note "14b/$h HOME and $cfgvar are the isolated home; go is offline with a per-cell cache" $ok "env: $(grep -E '^(HOME|'"$cfgvar"'|GO[A-Z]+)=' "$ev" | tr '\n' ' ')"
  want="$(cd "$AW" && pwd -P)"
  if [[ "$(cat "$cwdf")" == "$want" ]] && ! grep -q '^OLDPWD=' "$ev"; then ok=0; else ok=1; fi
  note "14c/$h cwd is the workdir (no OLDPWD pointing elsewhere)" $ok "cwd: $(cat "$cwdf")"
done

# permission flags per agent_mode, exactly
ESC='Bash(go test *-exec*) Bash(go test *-toolexec*) Bash(go build *-o*) Bash(go vet *-vettool*) Bash(git diff *--output*) Bash(git -c *) Bash(git --exec-path*)'
RO_BASH="Bash(go version:*) Bash(go build:*) Bash(go vet:*) Bash(go test:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*)"
adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; av="$AH/claude.argv"   # no OS sandbox: the narrow allowlist is the only confinement
if [[ "$(argafter "$av" --permission-mode)" == dontAsk && "$(argafter "$av" --allowedTools)" == "Read Glob Grep $RO_BASH" \
   && "$(argafter "$av" --disallowedTools)" == "Edit Write NotebookEdit WebFetch WebSearch $ESC" ]]; then ok=0; else ok=1; fi
note "14d claude read-only, sandbox OFF: dontAsk + the narrow allow/deny lists, exactly" $ok "$(tr '\n' '|' <"$av")"
adapter claude workspace-write CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; av="$AH/claude.argv"
if [[ "$(argafter "$av" --permission-mode)" == acceptEdits && "$(argafter "$av" --allowedTools)" == "Read Glob Grep Edit Write $RO_BASH Bash(gofmt:*)" \
   && "$(argafter "$av" --disallowedTools)" == "NotebookEdit WebFetch WebSearch $ESC" ]]; then ok=0; else ok=1; fi
note "14e claude workspace-write, sandbox OFF: acceptEdits + Edit/Write + gofmt, still no web" $ok "$(tr '\n' '|' <"$av")"
# A PROBE codex that records into its own isolated home (the only place a sandboxed host may write): argv, and whether an
# OUTSIDE write is denied (= it runs under the outer seatbelt wrapper). `fcx` is its install dir (readable under the profile).
fcx="$tmp/fakebin-cx"; mkdir -p "$fcx"
cat >"$fcx/codex" <<FAKE
#!/usr/bin/env bash
R="\$CODEX_HOME"; cat >/dev/null
printf '%s\n' "\$@" >"\$R/codex.argv"; env >"\$R/codex.env"
if touch "$tmp/outside/canary-cx" 2>/dev/null; then echo wrapped=no >"\$R/codex.wrapped"; rm -f "$tmp/outside/canary-cx"; else echo wrapped=yes >"\$R/codex.wrapped"; fi
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
FAKE
chmod +x "$fcx/codex"
# 14f: bypassPermissions / --dangerously never appear (either host, either mode); and codex's `danger-full-access`
# appears ONLY together with the outer sandbox-exec wrapper (the probe codex sees whether it is wrapped). Before the sandbox
# work this asserted that danger-full-access never appeared at all; the protection is the same: Codex's own sandbox is
# never turned off in a run whose only confinement it would have been.
bad=""; sbn=0
for m in read-only workspace-write; do
  adapter claude "$m" CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123; ac="$(cat "$AH/claude.argv")"
  CXSB=1 adapter codex "$m" CODEX_API_KEY=k PATH="$fcx:$PATH"; arc=$?; ax="$(cat "$AH/codex.argv" 2>/dev/null)"; wr="$(cat "$AH/codex.wrapped" 2>/dev/null)"
  [[ "$ac$ax" == *bypassPermissions* || "$ac$ax" == *dangerously* ]] && bad="$bad bypass/$m"
  if [[ "$ax" == *danger-full-access* && "$wr" != wrapped=yes ]]; then bad="$bad unwrapped-danger/$m"; fi
  if [[ "$PLATFORM" == Darwin ]]; then   # sandbox ON (default): the wrapper must be there and danger-full-access with it
    [[ $arc -eq 0 && "$ax" == *danger-full-access* && "$wr" == wrapped=yes ]] && sbn=$((sbn + 1)) || bad="$bad sandboxed-run/$m"
  fi
  adapter codex "$m" CODEX_API_KEY=k PATH="$fcx:$PATH"; ax="$(cat "$AH/codex.argv" 2>/dev/null)"; wr="$(cat "$AH/codex.wrapped" 2>/dev/null)"   # opt-out
  if [[ "$ax" == *danger-full-access* || "$wr" != wrapped=no || "$ax" != *workspace-write* ]]; then bad="$bad optout/$m"; fi
done
if [[ -z "$bad" ]]; then ok=0; else ok=1; fi
note "14f bypassPermissions/--dangerously never appear; danger-full-access appears only with the sandbox-exec wrapper (and always with it on macOS)" $ok "problems:$bad"
# 14g: before, every codex run asserted `-s workspace-write`, `--add-dir <gocache>`, -C, --ignore-user-config; now that is the
# contract of the OPT-OUT path (EVAL_NO_SANDBOX=1, Codex's own sandbox), the sandboxed argv is asserted by 14t.
adapter codex read-only CODEX_API_KEY=k EVAL_NO_SANDBOX=1; xv="$frec/codex.argv"
if [[ "$(argafter "$xv" -s)" == workspace-write && "$(argafter "$xv" --add-dir)" == "$AG" && "$(argafter "$xv" -C)" == "$AW" ]] && grep -qx -- --ignore-user-config "$xv" \
   && ! grep -q 'danger-full-access\|approval_policy' "$xv"; then ok=0; else ok=1; fi
note "14g codex opt-out (EVAL_NO_SANDBOX=1): -s workspace-write, --add-dir <gocache>, -C <workdir>, --ignore-user-config, no danger-full-access" $ok "$(tr '\n' '|' <"$xv")"
adapter claude other CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123; rc=$?
if [[ $rc -ne 0 && ! -e "$AH/claude.argv" ]]; then ok=0; else ok=1; fi
note "14h an unknown agent_mode is refused before the host starts" $ok "rc=$rc"

# credentials: passed by name only, nothing in a bash -x trace, nothing printed
ADAPTER_SH_FLAGS=-x adapter claude read-only; arc=$?   # no env token -> credentials file route (TRACE-CANARY-456)
if [[ $arc -eq 0 ]] && grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=TRACE-CANARY-456' "$AH/claude.env" \
   && ! grep -q 'TRACE-CANARY-456\|REFRESH-CANARY' "$tmp/adapter.err" "$tmp/adapter.out" && ! grep -q REFRESH-CANARY "$AH/claude.env"; then ok=0; else ok=1; fi
note "14i claude: access token (never the refresh token) reaches the host, absent from a bash -x trace" $ok "rc=$arc"
ADAPTER_SH_FLAGS=-x adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123; arc=$?
if [[ $arc -eq 0 ]] && grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123' "$AH/claude.env" && ! grep -q 'CRED-CANARY-123' "$tmp/adapter.err" "$tmp/adapter.out"; then ok=0; else ok=1; fi
note "14j claude: exported token preferred over the credential file, absent from a bash -x trace" $ok "rc=$arc"
adapter claude read-only EVAL_CLAUDE_AUTH_DIR="$tmp/nocreds"; arc=$?
if [[ $arc -eq 78 && ! -e "$AH/claude.argv" ]]; then ok=0; else ok=1; fi
note "14k claude without any credential: exit 78 before the host starts" $ok "rc=$arc"

# codex credential lifecycle (fake real home; the real ~/.codex is never read)
cp "$realcodex/auth.json" "$tmp/auth.orig"
ADAPTER_SH_FLAGS=-x adapter codex read-only; arc=$?
if [[ $arc -eq 0 && "$(cat "$frec/codex.hadauth")" == yes && ! -e "$AH/auth.json" ]] && cmp -s "$realcodex/auth.json" "$tmp/auth.orig" \
   && ! grep -q 'ORIG-CANARY' "$tmp/adapter.err" "$tmp/adapter.out"; then ok=0; else ok=1; fi
note "14l codex: auth copy exists for the run, is gone after, real file untouched, nothing printed" $ok "rc=$arc had=$(cat "$frec/codex.hadauth" 2>&1)"
if grep -q 'CODEX_API_KEY' "$frec/codex.env"; then ok=1; else ok=0; fi
note "14m codex: no API key variable when the auth.json route is used" $ok "env had CODEX_API_KEY"
: >"$frec/rotate"
adapter codex read-only; arc=$?
perm="$(python3 -I -B -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$realcodex/auth.json")"
if [[ $arc -eq 0 && ! -e "$AH/auth.json" && "$(cat "$realcodex/auth.json")" == *ROTATED-CANARY* && "$perm" == 0o600 \
   && -z "$(find "$realcodex" -name '.auth.*' | head -1)" ]]; then ok=0; else ok=1; fi
note "14n codex: a rotated token is written back atomically (600) and the copy removed" $ok "rc=$arc perm=$perm"
rm -f "$frec/rotate"; echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
adapter codex read-only CODEX_API_KEY=apikey-canary; arc=$?
if [[ $arc -eq 0 && "$(cat "$frec/codex.hadauth")" == no && "$(grep -c '^CODEX_API_KEY=apikey-canary$' "$frec/codex.env")" == 1 ]]; then ok=0; else ok=1; fi
note "14o codex: an exported CODEX_API_KEY is preferred and no auth.json is copied" $ok "rc=$arc"
# EVAL_KEEP=1 through run.sh: the dir stays, the credential does not
keeptmp="$tmp/keeptmp"; mkdir -p "$keeptmp"; ktask="$(mktask "$corpus" prod-review t-keep dev good)"
env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 PATH="$fb:$PATH" HOME="$realhome" TMPDIR="$keeptmp" EVAL_KEEP=1 EVAL_CODEX_REAL_HOME="$realcodex" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$ktask" --arm skill --host codex --rep 1 --out "$tmp/r14p.jsonl" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && "$(nrows "$tmp/r14p.jsonl")" == 1 && -n "$(find "$keeptmp" -mindepth 1 -maxdepth 1 -name 'eval-cell.*' | head -1)" \
   && -z "$(find "$keeptmp" -name auth.json | head -1)" && "$(cat "$frec/codex.hadauth")" == yes ]]; then ok=0; else ok=1; fi
note "14p EVAL_KEEP=1 keeps the cell dir but never the credential copy" $ok "rc=$rc left: $(find "$keeptmp" -name 'auth.json' | head -2 | tr '\n' ' ')"

# ---- 15: Claude is confined by a real seatbelt sandbox (fake claude, REAL sandbox-exec) ----
# A PATH without sandbox-exec: every other tool on PATH is symlinked in.
nosb="$tmp/nosb"; mkdir -p "$nosb"
python3 -I -B - "$nosb" "$PATH" <<'PY'
import os, sys
dst = sys.argv[1]
for d in sys.argv[2].split(":"):
    if not os.path.isdir(d): continue
    for n in os.listdir(d):
        p = os.path.join(d, n)
        if n == "sandbox-exec" or not os.access(p, os.X_OK) or os.path.isdir(p): continue
        l = os.path.join(dst, n)
        if not os.path.lexists(l):
            try: os.symlink(p, l)
            except OSError: pass
PY
TOK=CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123
if darwin_only 15a; then
rm -f "$tmp/outside/canary"   # earlier sandbox-OFF cases (14d/14e) legitimately wrote it
adapter claude read-only "$TOK"; arc=$?; th="$AH/claude.touch"
if [[ $arc -eq 0 ]] && grep -qx 'outside=denied' "$th" && grep -qx 'home=written' "$th" && grep -qx 'work=denied' "$th" \
   && grep -qx 'gocache=written' "$th" && grep -qx 'tmp=written' "$th" && [[ ! -e "$tmp/outside/canary" ]] \
   && [[ -z "$(find "$AH" \( -name '*.sb' -o -name '.eval-seatbelt*' -o -name 'sbx.*' \) | head -1)" ]]; then ok=0; else ok=1; fi
note "15a read-only: seatbelt denies writes outside AND in the workdir; home, GOCACHE, TMPDIR writable; no profile file under the agent's home" $ok "rc=$arc touch: $(tr '\n' ' ' <"$th" 2>&1) $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 15b; then
adapter claude workspace-write "$TOK"; arc=$?; th="$AH/claude.touch"
if [[ $arc -eq 0 ]] && grep -qx 'outside=denied' "$th" && grep -qx 'work=written' "$th"; then ok=0; else ok=1; fi
note "15b workspace-write: the workdir is writable, everything else outside the allowed set is not" $ok "touch: $(tr '\n' ' ' <"$th" 2>&1)"
fi
if darwin_only 15n; then
# a fake caller HOME (never the real one) holds the canaries; the task dir and the repo corpus are the answer key
adapter claude read-only "$TOK" EVAL_TASK_DIR="$good"; arc=$?; rd="$AH/claude.read"; th="$AH/claude.touch"
if [[ $arc -eq 0 && -n "$corpusfile" ]] && grep -qx 'ssh=denied' "$rd" && grep -qx 'claudecfg=denied' "$rd" && grep -qx 'taskdir=denied' "$rd" \
   && grep -qx 'corpus=denied' "$rd" && grep -qx 'workfile=read' "$rd" && grep -qx 'work=denied' "$th"; then ok=0; else ok=1; fi
note "15n sandbox: secrets (~/.ssh, ~/.claude*), the task dir and the repo corpus are unreadable; the workdir is readable, not writable" $ok "rc=$arc read: $(tr '\n' ' ' <"$rd" 2>&1) touch: $(grep '^work=' "$th" 2>&1)"
fi
if darwin_only 15o; then
adapter claude read-only "$TOK"; av="$AH/claude.argv"
o1="$(argafter "$av" --allowedTools)|$(argafter "$av" --disallowedTools)|$(argafter "$av" --permission-mode)"
adapter claude workspace-write "$TOK"; av="$AH/claude.argv"
o2="$(argafter "$av" --allowedTools)|$(argafter "$av" --disallowedTools)|$(argafter "$av" --permission-mode)"
if [[ "$o1" == "Read Glob Grep Bash|Edit Write NotebookEdit WebFetch WebSearch|dontAsk" && "$o2" == "Read Glob Grep Edit Write Bash|NotebookEdit WebFetch WebSearch|acceptEdits" ]]; then ok=0; else ok=1; fi
note "15o sandbox ON: unrestricted Bash, no Bash(...) patterns, no escape-flag denies (read-only and workspace-write)" $ok "ro=$o1 ww=$o2"
fi
runclaude() { # runclaude <task> <outfile> [env...] -> row file; kept home in $KT
  KT="$tmp/kt$((++kn))"; mkdir -p "$KT"; local task="$1" res="$2"; shift 2
  env -u CODEX_API_KEY ${nosb_default[@]+"${nosb_default[@]}"} PATH="$fb:$PATH" HOME="$realhome" TMPDIR="$KT" EVAL_KEEP=1 CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_SKILLS_ROOT="$skills" "$@" \
    bash "$here/run.sh" --task "$task" --arm bare --host claude --rep 1 --out "$res" >/dev/null 2>"$tmp/runclaude.err"
}
kn=0
# ---- 15p-15v: user data is DEFAULT-DENY (fake claude, REAL sandbox-exec) ----
# 15p-15s run against a FAKE tree: the adapter's selftest-only --deny-roots (adapter arg DENYROOTS=) points the denied roots at $FT instead of the
# user's real /Users, so the canaries are ours. The probe host records what it can and cannot do.
FT="$tmp/ft"; DR="$tmp/aaa-decoy:$FT"; mkdir -p "$tmp/aaa-decoy"   # the decoy root sorts FIRST: a rule honouring only its first filter would miss $FT
FHOME="$FT/u/me"; FREPO="$FT/dev/repo"; FREPO2="$FT/dev2/repo-copy"; FCELLS="$FT/cells"; SK="$tmp/sk"
fbs="$tmp/fakebin-sb"; REAL_USER_HOME="$HOME"
mkdir -p "$fbs" "$FHOME/.ssh" "$FHOME/.claude-sfx" "$FHOME/.config/tool" "$FREPO/benchmarks/eval/corpus/x" "$FREPO/benchmarks/eval/results" "$FT/dev2" "$FCELLS" "$SK"
echo SSH-CANARY >"$FHOME/.ssh/id"; echo HIST-CANARY >"$FHOME/.claude-sfx/history.jsonl"; echo CRED-FILE-CANARY >"$FHOME/.config/tool/creds"
echo GITCFG-CANARY >"$FHOME/.gitconfig"; echo ZSH-CANARY >"$FHOME/.zsh_history"
echo 'hidden grader' >"$FREPO/benchmarks/eval/corpus/x/grade.sh"; echo '{}' >"$FREPO/benchmarks/eval/results/r.jsonl"
( cd "$FREPO" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q . && git add -A \
  && git -c user.name=e -c user.email=e@e.invalid -c commit.gpgsign=false commit -q -m seed ) >/dev/null 2>&1
cp -R "$FREPO" "$FREPO2"
GITOBJ='HEAD:benchmarks/eval/corpus/x/grade.sh'
if GIT_CONFIG_GLOBAL=/dev/null git --git-dir="$FREPO/.git" cat-file -p "$GITOBJ" >/dev/null 2>&1; then gsetup=0; else gsetup=1; fi
note "15p0 setup: the fake repo is a real git repo whose object store yields the hidden file outside the sandbox" $gsetup "git cat-file failed on $FREPO"
# sockets: docker.sock under the denied root, docker.sock OUTSIDE every denied root (only the socket rule can stop it), a control
cat >"$tmp/sockd.py" <<'PY'
import socket, sys, threading, time
def serve(p):
    s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(5)
    while True:
        c, _ = s.accept()
        try:
            c.send(b"hi")
        except OSError:   # a client that already hung up must not kill the server
            pass
        c.close()
for p in sys.argv[1:]:
    threading.Thread(target=serve, args=(p,), daemon=True).start()
print("READY", flush=True)
time.sleep(300)
PY
echo TMP-CANARY >"$tmp/ftmp-canary"; echo INST-CANARY >"$fbs/install-canary"
SOCK_IN="$FT/docker.sock"; SOCK_ROOT="$FT/plain.sock"; SOCK_OUT="$SK/docker.sock"; SOCK_CTL="$SK/ctl.sock"
python3 -I -B "$tmp/sockd.py" "$SOCK_IN" "$SOCK_ROOT" "$SOCK_OUT" "$SOCK_CTL" >"$tmp/sockd.out" 2>&1 &
SOCKD=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do grep -q READY "$tmp/sockd.out" 2>/dev/null && break; sleep 0.1; done
sk_probe='import socket,sys
s=socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("connected")
except OSError:
    print("refused")'
ok=0; for s in "$SOCK_IN" "$SOCK_ROOT" "$SOCK_OUT" "$SOCK_CTL"; do [[ "$(python3 -I -B -c "$sk_probe" "$s" 2>/dev/null)" == connected ]] || ok=1; done
note "15q0 setup: all four unix sockets answer outside the sandbox" $ok "sockd: $(head -c 200 "$tmp/sockd.out")"
cat >"$fbs/sandbox-exec" <<FAKE
#!/usr/bin/env bash
# records which profile the adapter generated, then runs the REAL sandbox-exec
if [ "\$1" = -f ]; then printf '%s' "\$2" >"$frec/sbx.profile"; cp "\$2" "$frec/sbx.copy"; fi
exec /usr/bin/sandbox-exec "\$@"
FAKE
cat >"$fbs/claude" <<FAKE
#!/usr/bin/env bash
R="\$CLAUDE_CONFIG_DIR"; cat >/dev/null
out="\$R/probe.out"; : >"\$out"
p() { echo "\$1=\$2" >>"\$out"; }
r() { if cat "\$2" >/dev/null 2>&1; then p "\$1" read; else p "\$1" denied; fi; }
w() { if touch "\$2" 2>/dev/null; then p "\$1" written; else p "\$1" denied; fi; }
sk() { v="\$(python3 -I -B -c '$sk_probe' "\$2" 2>/dev/null)"; p "\$1" "\${v:-error}"; }
r ssh "$FHOME/.ssh/id"; r history "$FHOME/.claude-sfx/history.jsonl"; r toolcfg "$FHOME/.config/tool/creds"; r gitconfig "$FHOME/.gitconfig"
r zhist "$FHOME/.zsh_history"; r corpus "$FREPO/benchmarks/eval/corpus/x/grade.sh"; r results "$FREPO/benchmarks/eval/results/r.jsonl"
r repocopy "$FREPO2/benchmarks/eval/corpus/x/grade.sh"; r githeadfile "$FREPO/.git/HEAD"
if ls "$FHOME" >/dev/null 2>&1; then p lshome listed; else p lshome denied; fi
if git --git-dir="$FREPO/.git" cat-file -p "$GITOBJ" >/dev/null 2>&1; then p gitobj read; else p gitobj denied; fi
if git --git-dir="$FREPO2/.git" cat-file -p "$GITOBJ" >/dev/null 2>&1; then p gitobj2 read; else p gitobj2 denied; fi
prof="\$(cat "$frec/sbx.profile" 2>/dev/null)"; if [ -n "\$prof" ]; then p profknown yes; else p profknown no; fi
if [ -n "\$prof" ] && cat "\$prof" >/dev/null 2>&1; then p profile read; else p profile denied; fi
if [ -n "\$prof" ] && ls "\$(dirname "\$prof")" >/dev/null 2>&1; then p profdir listed; else p profdir denied; fi
if ls "$REAL_USER_HOME" >/dev/null 2>&1; then p realhome listed; else p realhome denied; fi
sk sockin "$SOCK_IN"; sk sockroot "$SOCK_ROOT"; sk sockout "$SOCK_OUT"; sk sockctl "$SOCK_CTL"
r workfile "\$PWD/README.md"; r tmpfile "$tmp/ftmp-canary"; r installfile "\$(dirname "\$0")/install-canary"
if git status --short >/dev/null 2>&1; then p gitstatus ok; else p gitstatus failed; fi
git diff >"\$R/diff.out" 2>/dev/null; if grep -q more "\$R/diff.out"; then p gitdiff ok; else p gitdiff failed; fi
w home "\$R/canary"; w gocache "\$GOCACHE/canary"; w tmp "\$TMPDIR/canary"; w work "\$PWD/canary"
printf '%s\n' "\$PWD" "\$HOME" "\$TMPDIR" "\$GOCACHE" "\$CLAUDE_CONFIG_DIR" "\$CLAUDE_CODE_TMPDIR" "\$@" >"\$R/names.txt"
echo '{"result":"OK","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2}}'
FAKE
chmod +x "$fbs/sandbox-exec" "$fbs/claude"
TID=zq7taskid; ttask="$(TASK_KIND=seeded mktask "$tmp/tcorp" prod-review "$TID" dev good)"
pvg() { grep -qx "$2" "$1/probe.out"; }   # pvg <home> <name=value>
pvs() { tr '\n' ' ' <"$1/probe.out" 2>/dev/null; }
if darwin_only 15p; then
adapter claude read-only "$TOK" ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$fbs:$fb:$PATH" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask"; arc=$?; PH="$AH"; ok=1
if [[ $arc -eq 0 ]] && pvg "$PH" ssh=denied && pvg "$PH" history=denied && pvg "$PH" toolcfg=denied && pvg "$PH" gitconfig=denied && pvg "$PH" zhist=denied \
   && pvg "$PH" corpus=denied && pvg "$PH" results=denied && pvg "$PH" repocopy=denied && pvg "$PH" githeadfile=denied && pvg "$PH" lshome=denied \
   && pvg "$PH" gitobj=denied && pvg "$PH" gitobj2=denied && pvg "$PH" profknown=yes && pvg "$PH" profile=denied && pvg "$PH" profdir=denied \
   && [[ "$(cat "$frec/sbx.profile")" != "$PH"/* ]]; then ok=0; fi
note "15p default-deny: the fake home's secrets/history/config, the repo (corpus, results, .git object store), a repo copy and the sandbox profile (and its dir) are unreadable; the home is not listable" $ok "rc=$arc probe: $(pvs "$PH") $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 15q; then
ok=1; if [[ $arc -eq 0 ]] && pvg "$PH" sockctl=connected && pvg "$PH" sockin=refused && pvg "$PH" sockroot=refused && pvg "$PH" sockout=refused; then ok=0; fi
note "15q a unix socket cannot be connected to when named docker.sock (under a denied root AND outside every root) or when it lies under a denied root under any name; a control socket outside the roots can" $ok "probe: $(pvs "$PH")"
fi
if darwin_only 15r; then
ok=1; if [[ $arc -eq 0 ]] && pvg "$PH" workfile=read && pvg "$PH" gitstatus=ok && pvg "$PH" gitdiff=ok && pvg "$PH" home=written && pvg "$PH" gocache=written && pvg "$PH" tmp=written; then ok=0; fi
note "15r the cell still works: workdir readable, git status/diff run there, home/GOCACHE/TMPDIR writable" $ok "probe: $(pvs "$PH")"
fi
if darwin_only 15s; then
ok=1; pvg "$PH" work=denied && ok=0
adapter claude workspace-write "$TOK" ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$fbs:$fb:$PATH" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask"; arc=$?
if [[ $arc -eq 0 ]] && pvg "$AH" work=written && pvg "$AH" ssh=denied && [[ $ok -eq 0 ]]; then ok=0; else ok=1; fi
note "15s workdir write: denied in read-only, allowed in workspace-write (secrets still denied)" $ok "ww probe: $(pvs "$AH")"
fi
if darwin_only 15t; then
# through run.sh: the cell's dirs must say nothing about the task (id, kind, skill) and nor must the profile
runclaude "$ttask" "$tmp/r15t.jsonl" PATH="$fbs:$fb:$PATH"; rc=$?
tprobe="$(find "$KT" -name names.txt | head -1)"; hits=""
if [[ -n "$tprobe" ]]; then hits="$(grep -Eio "$TID|seeded|clean" "$tprobe" "$frec/sbx.copy" | head -3 | tr '\n' ' ')"; fi
if [[ $rc -eq 0 && -n "$tprobe" && -s "$frec/sbx.copy" && -z "$hits" ]]; then ok=0; else ok=1; fi
note "15t temp dir names, pwd/HOME/TMPDIR/GOCACHE/argv and the profile never contain the task id, kind or 'seeded'/'clean'" $ok "rc=$rc hits: $hits names: $(head -c 300 "$tprobe" 2>/dev/null | tr '\n' ' ')"
fi
kill "$SOCKD" 2>/dev/null
if darwin_only 15u; then
# the DEFAULT roots, against the caller's real home: only its path is used, its contents are never read or printed
adapter claude read-only "$TOK" AGIT=1 PATH="$fbs:$fb:$PATH" EVAL_TASK_DIR="$ttask"; arc=$?
fbsrp="$(python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$fbs")"; tmprp="$(python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$tmp")"
if [[ $arc -eq 0 ]] && pvg "$AH" realhome=denied && pvg "$AH" workfile=read && pvg "$AH" gitstatus=ok && pvg "$AH" corpus=denied \
   && pvg "$AH" tmpfile=denied && pvg "$AH" installfile=read && [[ -s "$tmp/ftmp-canary" ]] \
   && grep -qF "(subpath \"$fbsrp\")" "$frec/sbx.copy" && ! grep -qF "(subpath \"$tmprp\")" "$frec/sbx.copy"; then ok=0; else ok=1; fi
note "15u default roots: ls of the caller's real home fails while a workdir read and git status work; a file under the denied temp tree is unreadable to the fake host and the same kind of file in its install dir is readable; only the install dir (not its parent) is re-allowed" $ok "rc=$arc probe: $(pvs "$AH") $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 15v; then
# the real CLI must START under the generated profile (no model call: --version). The adapter's own
# resolution (real path of `claude`, its dir re-allowed) is replayed here against the same seatbelt.py.
if cl="$(command -v claude)" && [[ -n "$cl" ]]; then
  vroot="$tmp/vcell"; mkdir -p "$vroot/work" "$vroot/home"
  real="$(python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$cl")"
  python3 -I -B "$here/lib/seatbelt.py" "$vroot/work" "$vroot/home" "$vroot/gocache" "$vroot/tmp" read-only --allow-read "$(dirname "$real")" \
    --deny-read "$(cd "$here/../.." && pwd)" >"$vroot/p.sb"; prc=$?
  vout="$( (cd "$vroot/work" && env -i PATH="$PATH" HOME="$vroot/home" CLAUDE_CONFIG_DIR="$vroot/home" TMPDIR="$vroot/tmp" /usr/bin/sandbox-exec -f "$vroot/p.sb" "$real" --version) 2>&1)"; vrc=$?
  if [[ $prc -eq 0 && $vrc -eq 0 && "$vout" == *Claude* ]]; then ok=0; else ok=1; fi
  note "15v the real claude binary starts under the generated profile (claude --version exits 0)" $ok "prc=$prc vrc=$vrc out: $(echo "$vout" | head -c 200)"
else
  printf '  SKIP  15v (no claude on PATH; not counted)\n'
fi
fi
if darwin_only 15w; then
# no environment variable can weaken the roots: the old hook name and any other EVAL_SEATBELT_* are inert
adapter claude read-only "$TOK" AGIT=1 PATH="$fbs:$fb:$PATH" EVAL_TASK_DIR="$ttask" EVAL_SEATBELT_DENY_ROOTS="$FT" EVAL_SEATBELT_DENY_ROOT="$FT" EVAL_SEATBELT_ROOTS=/nonexistent EVAL_SEATBELT_OFF=1; arc=$?
if [[ $arc -eq 0 ]] && pvg "$AH" realhome=denied && pvg "$AH" tmpfile=denied && grep -qF '(subpath "/Users")' "$frec/sbx.copy" && ! grep -qF "$FT" "$frec/sbx.copy"; then ok=0; else ok=1; fi
note "15w EVAL_SEATBELT_DENY_ROOTS (and any EVAL_SEATBELT_*) exported in the caller's environment has NO effect on the generated profile" $ok "rc=$arc probe: $(pvs "$AH")"
fi
if darwin_only 15x; then
# the CLI's install dir is re-allowed for READ; if it would contain a denied path (the real auth/config dir) the profile is refused
mkdir -p "$tmp/inst/auth"; cp "$fbs/claude" "$tmp/inst/claude"; chmod +x "$tmp/inst/claude"
adapter claude read-only "$TOK" PATH="$tmp/inst:$fbs:$fb:$PATH" EVAL_CLAUDE_AUTH_DIR="$tmp/inst/auth"; arc=$?
if [[ $arc -eq 79 && ! -e "$AH/probe.out" ]] && grep -q 'lies at or above' "$tmp/adapter.err" 2>/dev/null; then ok=0; else ok=1; fi
note "15x install dir that contains the real auth/config dir: the profile is refused (exit 79), the host never starts" $ok "rc=$arc $(head -c 300 "$tmp/adapter.err")"
adapter claude read-only "$TOK" PATH="$tmp/inst:$fbs:$fb:$PATH"; arc=$?
if [[ $arc -eq 0 && -e "$AH/probe.out" ]]; then ok=0; else ok=1; fi
note "15x2 control: the same install dir with the auth dir elsewhere starts normally" $ok "rc=$arc $(head -c 300 "$tmp/adapter.err")"
fi
if darwin_only 15y; then
# a re-allowed FILE (the --output-schema) is reachable by a CLI that lstat()s its ancestors: metadata only there, never data or siblings
sy="$tmp/y15"; mkdir -p "$sy/c/lib" "$sy/c/other"; echo SCHEMA >"$sy/c/lib/s.json"; echo SIB >"$sy/c/lib/sib.json"; echo OTH >"$sy/c/other/o.txt"
python3 -I -B "$here/lib/seatbelt.py" "$sy/cell/work" "$sy/cell/home" "$sy/cell/gc" "$sy/cell/tmp" read-only --deny-root "$tmp" --reallow-read "$sy/c/lib/s.json" >"$sy/p.sb"; prc=$?
sby() { /usr/bin/sandbox-exec -f "$sy/p.sb" "$@" >/dev/null 2>&1 && echo ok || echo denied; }
y1="$(sby /bin/cat "$sy/c/lib/s.json")"; y2="$(sby /usr/bin/stat "$sy/c/lib")"; y3="$(sby /usr/bin/stat "$sy/c")"; y4="$(sby /bin/cat "$sy/c/lib/sib.json")"; y5="$(sby /usr/bin/stat "$sy/c/lib/sib.json")"; y6="$(sby /bin/ls "$sy/c/lib")"; y7="$(sby /bin/cat "$sy/c/other/o.txt")"
if [[ $prc -eq 0 && "$y1" == ok && "$y2" == ok && "$y3" == ok && "$y4" == denied && "$y5" == denied && "$y6" == denied && "$y7" == denied ]]; then ok=0; else ok=1; fi
sl="$(mktemp -d /tmp/eval-y15.XXXXXX)"; echo SCHEMA >"$sl/s.json"   # a path through the symlinked /tmp, not its realpath
python3 -I -B "$here/lib/seatbelt.py" "$sy/cell/work" "$sy/cell/home" "$sy/cell/gc" "$sy/cell/tmp" read-only --reallow-read "$sl/s.json" >"$sy/p2.sb"; prc2=$?
y8="$(/usr/bin/sandbox-exec -f "$sy/p2.sb" /usr/bin/stat "$sl" >/dev/null 2>&1 && echo ok || echo denied)"; y9="$(/usr/bin/sandbox-exec -f "$sy/p2.sb" /bin/cat "$sl/s.json" >/dev/null 2>&1 && echo ok || echo denied)"; rm -rf "$sl"
if [[ $ok -eq 0 && $prc2 -eq 0 && "$y8" == ok && "$y9" == ok ]]; then ok=0; else ok=1; fi
note "15y re-allowed file: readable, its ancestors stat-able; sibling file (cat+stat), directory listing and other dirs stay denied" $ok "prc=$prc cat=$y1 stat-dir=$y2 stat-parent=$y3 cat-sib=$y4 stat-sib=$y5 ls=$y6 cat-other=$y7 via-symlink stat=$y8 cat=$y9"
fi
adapter claude read-only "$TOK" EVAL_CLAUDE_NO_SANDBOX=0 PATH="$fb:$nosb"; arc=$?
if [[ $arc -eq 79 && ! -e "$AH/claude.argv" ]]; then ok=0; else ok=1; fi
note "15c no sandbox-exec -> adapter exits 79 and the host never starts (no silent unconfined run)" $ok "rc=$arc $(head -c 160 "$tmp/adapter.err")"
adapter claude read-only "$TOK" EVAL_CLAUDE_NO_SANDBOX=1; arc=$?; th="$AH/claude.touch"
if [[ $arc -eq 0 ]] && grep -qx 'outside=written' "$th" && grep -q 'WARNING.*UNCONFINED' "$tmp/adapter.err"; then ok=0; else ok=1; fi
rm -f "$tmp/outside/canary"
note "15d EVAL_CLAUDE_NO_SANDBOX=1: runs unconfined WITH a loud stderr warning" $ok "rc=$arc touch: $(tr '\n' ' ' <"$th" 2>&1)"
adapter claude read-only "$TOK" EVAL_CLAUDE_NO_SANDBOX=1; dv="$(argafter "$AH/claude.argv" --disallowedTools)"; missing=""
for p in 'Bash(go test *-exec*)' 'Bash(go test *-toolexec*)' 'Bash(go build *-o*)' 'Bash(go vet *-vettool*)' 'Bash(git diff *--output*)' 'Bash(git -c *)' 'Bash(git --exec-path*)'; do
  [[ "$dv" == *"$p"* ]] || missing="$missing [$p]"
done
if [[ -z "$missing" ]]; then ok=0; else ok=1; fi
note "15e escape-flag deny patterns are present in --disallowedTools" $ok "missing:$missing"
# through run.sh: rows carry sandbox:<mode>; agent_mode really selects the permission mode (N3)
mkdir -p "$tmp/mcorp"; wtask="$(mktask "$tmp/mcorp" prod-review t-ww dev good)"
python3 -I -B - "$wtask/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agent_mode"] = "workspace-write"; json.dump(t, open(sys.argv[1], "w"))
PY
runclaude "$good" "$tmp/r15a.jsonl"; ro_arg="$(argafter "$(find "$KT" -name claude.argv | head -1)" --permission-mode)"
runclaude "$wtask" "$tmp/r15b.jsonl"; ww_arg="$(argafter "$(find "$KT" -name claude.argv | head -1)" --permission-mode)"
if [[ "$ro_arg" == dontAsk && "$ww_arg" == acceptEdits && "$(rowval "$tmp/r15a.jsonl" sandbox)" == "$want_sandbox" ]]; then ok=0; else ok=1; fi
note "15f run.sh passes the task's agent_mode through (read-only->dontAsk, workspace-write->acceptEdits), row sandbox:$want_sandbox" $ok "ro=$ro_arg ww=$ww_arg sandbox=$(rowval "$tmp/r15a.jsonl" sandbox)"
runclaude "$good" "$tmp/r15c.jsonl" EVAL_CLAUDE_NO_SANDBOX=1
if [[ "$(rowval "$tmp/r15c.jsonl" sandbox)" == off && "$(cat "$tmp/runclaude.err")" == *UNCONFINED* ]]; then ok=0; else ok=1; fi
note "15g NO_SANDBOX=1 through run.sh: row sandbox:off and a warning" $ok "sandbox=$(rowval "$tmp/r15c.jsonl" sandbox)"
runclaude "$good" "$tmp/r15d.jsonl" EVAL_CLAUDE_NO_SANDBOX=0 PATH="$fb:$nosb"; rc=$?
if [[ $rc -eq 3 && "$(rowval "$tmp/r15d.jsonl" error)" == sandbox && "$(rowval "$tmp/r15d.jsonl" pass)" == false && "$(rowval "$tmp/r15d.jsonl" sandbox)" == seatbelt ]]; then ok=0; else ok=1; fi
note "15h no sandbox-exec through run.sh: row error:sandbox, pass:false, exit 3" $ok "rc=$rc row: $(cut -c1-200 "$tmp/r15d.jsonl" 2>&1)"
# keychain route through a fake `security` on PATH (no env hook)
if darwin_only 15i; then
  # The canary is assembled from a variable so the literal never sits next to a
  # credential-shaped key name: the repo's secret scan is blocking and must stay
  # free of allowlist entries for test fixtures.
  kc_canary='KEYCHAIN-CANARY-789'
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$kc_canary" >"$frec/keychain"
  adapter claude read-only EVAL_CLAUDE_AUTH_DIR="$tmp/nocreds"; arc=$?
  if [[ $arc -eq 0 ]] && grep -qx "CLAUDE_CODE_OAUTH_TOKEN=${kc_canary}" "$AH/claude.env"; then ok=0; else ok=1; fi
  rm -f "$frec/keychain"
  note "15i keychain route works through a fake security binary found on PATH" $ok "rc=$arc"
fi
# 15k: a host that is not macOS (fake `uname` first on PATH, runs on BOTH platforms) refuses an unconfined run
fu="$tmp/fakeuname"; mkdir -p "$fu"; printf '#!/bin/sh\necho Linux\n' >"$fu/uname"; chmod +x "$fu/uname"
adapter claude read-only "$TOK" EVAL_CLAUDE_NO_SANDBOX=0 PATH="$fu:$fb:$PATH"; arc=$?
if [[ $arc -eq 79 && ! -e "$AH/claude.argv" && "$(cat "$tmp/adapter.err")" == *"macOS-only"* ]]; then ok=0; else ok=1; fi
note "15k non-Darwin (fake uname=Linux), no opt-out: adapter exits 79, host never starts" $ok "rc=$arc $(head -c 160 "$tmp/adapter.err")"
runclaude "$good" "$tmp/r15k.jsonl" EVAL_CLAUDE_NO_SANDBOX=0 PATH="$fu:$fb:$PATH"; rc=$?
if [[ $rc -eq 3 && "$(rowval "$tmp/r15k.jsonl" error)" == sandbox && "$(rowval "$tmp/r15k.jsonl" pass)" == false ]]; then ok=0; else ok=1; fi
note "15l non-Darwin through run.sh: row error:sandbox, pass:false, exit 3" $ok "rc=$rc row: $(cut -c1-200 "$tmp/r15k.jsonl" 2>&1)"
runclaude "$good" "$tmp/r15l.jsonl" EVAL_CLAUDE_NO_SANDBOX=1 PATH="$fu:$fb:$PATH"; rc=$?
if [[ $rc -eq 0 && "$(rowval "$tmp/r15l.jsonl" sandbox)" == off && "$(rowval "$tmp/r15l.jsonl" error)" != sandbox && "$(cat "$tmp/runclaude.err")" == *UNCONFINED* ]]; then ok=0; else ok=1; fi
note "15m non-Darwin + EVAL_CLAUDE_NO_SANDBOX=1: runs, row sandbox:off, warning on stderr" $ok "rc=$rc row: $(cut -c1-300 "$tmp/r15l.jsonl" 2>&1)"
# ---- 14q-14z: the Codex adapter runs under the SAME seatbelt profile as Claude (probe codex, REAL sandbox-exec) ----
# 14q: the generator refuses a Codex re-allow that would contain what stays denied (pure python, runs on both platforms)
qd="$tmp/q14"; mkdir -p "$qd/h/.codex/packages/rel/bin" "$qd/w"
python3 -I -B "$here/lib/seatbelt.py" "$qd/w" "$qd/home" "$qd/gc" "$qd/tmp" read-only --deny-root "$qd/h" --deny-read "$qd/h/.codex" --reallow-read "$qd/h/.codex" >/dev/null 2>"$qd/e1"; q1=$?
python3 -I -B "$here/lib/seatbelt.py" "$qd/w" "$qd/home" "$qd/gc" "$qd/tmp" read-only --deny-root "$qd/h" --deny-read "$qd/h/.codex" --reallow-read "$qd/h/.codex/packages/rel/bin" >"$qd/p.sb" 2>"$qd/e2"; q2=$?
python3 -I -B "$here/lib/seatbelt.py" "$qd/w" "$qd/home" "$qd/gc" "$qd/tmp" read-only --deny-root "$qd/h" --protect "$qd/h/.codex/packages" --reallow-read "$qd/h/.codex/packages/rel" >/dev/null 2>"$qd/e3"; q3=$?
if [[ $q1 -eq 2 && $q2 -eq 0 && $q3 -eq 2 ]] && grep -q 'lies at or above' "$qd/e1" && [[ "$(grep -c '^(allow file-read\* (subpath "[^"]*/packages/rel/bin"))$' "$qd/p.sb")" == 1 ]]; then ok=0; else ok=1; fi
note "14q seatbelt --reallow-read: refused when it contains a denied/protected path (the whole Codex home), accepted for its install dir only" $ok "rc=$q1/$q2/$q3 $(head -c 160 "$qd/e1")"
kcn=0
runcodex() { # runcodex <task> <outfile> [env...] -> row file; kept cell dir in $KC
  KC="$tmp/kc$((++kcn))"; mkdir -p "$KC"; local task="$1" res="$2"; shift 2
  env HOME="$realhome" TMPDIR="$KC" EVAL_KEEP=1 CODEX_API_KEY=k EVAL_CODEX_REAL_HOME="$realcodex" EVAL_SKILLS_ROOT="$skills" PATH="$fb:$PATH" "$@" \
    bash "$here/run.sh" --task "$task" --arm bare --host codex --rep 1 --out "$res" >/dev/null 2>"$tmp/runcodex.err"
}
# fake Codex install under a fake caller home: the real binary sits INSIDE the real Codex home, next to the auth stand-in,
# the config, a sibling file of its install dir and a sibling of the packages dir. $FT/$FHOME/$FREPO come from 15p.
CXR="$FHOME/.codex"; CXREL="$CXR/packages/standalone/releases/9.9.9"; mkdir -p "$CXREL/bin" "$CXR/packages/standalone/other" "$FHOME/.local/bin"
echo '{"canary":"CODEX-AUTH-CANARY"}' >"$CXR/auth.json"; chmod 600 "$CXR/auth.json"; echo CODEX-CFG-CANARY >"$CXR/config.toml"
echo SIBLING-CANARY >"$CXREL/sibling-canary"; echo PKG-CANARY >"$CXR/packages/standalone/other/canary"; echo BIN-CANARY >"$CXREL/bin/bin-canary"
cat >"$CXREL/bin/codex" <<FAKE
#!/usr/bin/env bash
R="\$CODEX_HOME"; cat >/dev/null
out="\$R/probe.out"; : >"\$out"
p() { echo "\$1=\$2" >>"\$out"; }
r() { if cat "\$2" >/dev/null 2>&1; then p "\$1" read; else p "\$1" denied; fi; }
w() { if touch "\$2" 2>/dev/null; then p "\$1" written; else p "\$1" denied; fi; }
printf '%s\n' "\$@" >"\$R/codex.argv"
r realauth "$CXR/auth.json"; r realcfg "$CXR/config.toml"; r sibling "$CXREL/sibling-canary"; r pkgother "$CXR/packages/standalone/other/canary"
pv=""; for a in "\$@"; do if [ "\$pv" = --output-schema ]; then r schema "\$a"; r schemadir "\$(dirname "\$a")/sibling-secret"; fi; pv="\$a"; done
r instbin "\$(dirname "\$0")/bin-canary"; r ssh "$FHOME/.ssh/id"; r corpus "$FREPO/benchmarks/eval/corpus/x/grade.sh"
if ls "$CXR" >/dev/null 2>&1; then p lscodexhome listed; else p lscodexhome denied; fi
if git --git-dir="$FREPO/.git" cat-file -p "$GITOBJ" >/dev/null 2>&1; then p gitobj read; else p gitobj denied; fi
prof="\$(cat "$frec/sbx.profile" 2>/dev/null)"; if [ -n "\$prof" ]; then p profknown yes; else p profknown no; fi
if [ -n "\$prof" ] && cat "\$prof" >/dev/null 2>&1; then p profile read; else p profile denied; fi
r homeauth "\$R/auth.json"; r workfile "\$PWD/README.md"
if git status --short >/dev/null 2>&1; then p gitstatus ok; else p gitstatus failed; fi
w home "\$R/canary"; w gocache "\$GOCACHE/canary"; w tmp "\$TMPDIR/canary"; w work "\$PWD/canary"
if [ -f "$frec/rotate-cx" ]; then echo '{"canary":"ROTATED-CX"}' >"\$R/auth.json"; fi
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
FAKE
chmod +x "$CXREL/bin/codex"; ln -sf "$CXREL/bin/codex" "$FHOME/.local/bin/codex"
CXP="$FHOME/.local/bin:$fbs:$fb:$PATH"
rprobe() { python3 -I -B -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }
if darwin_only 14r; then
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?; PH="$AH"
if [[ $arc -eq 0 ]] && pvg "$PH" realauth=denied && pvg "$PH" realcfg=denied && pvg "$PH" sibling=denied && pvg "$PH" pkgother=denied && pvg "$PH" lscodexhome=denied \
   && pvg "$PH" ssh=denied && pvg "$PH" corpus=denied && pvg "$PH" gitobj=denied && pvg "$PH" profknown=yes && pvg "$PH" profile=denied \
   && pvg "$PH" instbin=read && pvg "$PH" homeauth=read && pvg "$PH" workfile=read && [[ ! -e "$AH/auth.json" ]] && grep -q CODEX-AUTH-CANARY "$CXR/auth.json"; then ok=0; else ok=1; fi
note "14r codex under the profile: the real Codex home (auth, config, a sibling of its install dir, the packages dir), ~/.ssh, the corpus, the .git object store and the profile are unreadable; its own install dir, its home's auth copy and the workdir are readable; the copy is scrubbed" $ok "rc=$arc probe: $(pvs "$PH") $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 14s; then
ok=1; pvg "$PH" work=denied && pvg "$PH" home=written && pvg "$PH" gocache=written && pvg "$PH" tmp=written && pvg "$PH" gitstatus=ok && ok=0
CXSB=1 adapter codex workspace-write ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
if [[ $arc -eq 0 && $ok -eq 0 ]] && pvg "$AH" work=written && pvg "$AH" home=written && pvg "$AH" gitstatus=ok && pvg "$AH" workfile=read && pvg "$AH" realauth=denied && pvg "$AH" sibling=denied; then ok=0; else ok=1; fi
note "14s codex workdir write: denied in read-only, allowed in workspace-write (home/GOCACHE/TMPDIR always writable, workdir readable, git status runs, secrets still denied)" $ok "ww probe: $(pvs "$AH")"
fi
if darwin_only 14s2; then
# codex reads its --output-schema FILE itself: that file (under a denied root) is readable, a sibling of it is not
mkdir -p "$FT/schemas"; echo '{}' >"$FT/schemas/output.schema.json"; echo SCHEMA-SIB >"$FT/schemas/sibling-secret"
ADAPTER_SCHEMA="$FT/schemas/output.schema.json" CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
if [[ $arc -eq 0 ]] && pvg "$AH" schema=read && pvg "$AH" schemadir=denied && pvg "$AH" realauth=denied && pvg "$AH" ssh=denied; then ok=0; else ok=1; fi
note "14s2 codex --output-schema: the schema file under a denied root is readable under the profile, a sibling file next to it is not" $ok "rc=$arc probe: $(pvs "$AH") $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 14t; then
# through run.sh with the DEFAULT roots: both hosts are 'seatbelt'; the argv is the sandboxed one; only the install dir is re-allowed
runcodex "$ttask" "$tmp/r14t.jsonl" PATH="$CXP" EVAL_CODEX_REAL_HOME="$CXR"; rc=$?
cav="$(find "$KC" -name codex.argv | head -1)"; binrp="$(rprobe "$CXREL/bin")"; relrp="$(rprobe "$CXREL")"
if [[ $rc -eq 0 && -n "$cav" && "$(rowval "$tmp/r14t.jsonl" sandbox)" == seatbelt && "$(argafter "$cav" -s)" == danger-full-access && "$(argafter "$cav" -c)" == approval_policy=never ]] \
   && ! grep -q -- '--add-dir\|workspace-write\|dangerously' "$cav" && grep -qx -- --ignore-user-config "$cav" && grep -qx -- - "$cav" \
   && grep '^(allow file-read\*' "$frec/sbx.copy" | grep -qF "(subpath \"$binrp\")" && ! grep '^(allow file-read\*' "$frec/sbx.copy" | grep -qF "(subpath \"$relrp\")" \
   && grep -qF "(deny file-read* file-write* (subpath \"$(rprobe "$CXR")\"))" "$frec/sbx.copy"; then ok=0; else ok=1; fi
note "14t codex via run.sh: row sandbox:seatbelt, argv -s danger-full-access + approval_policy=never (no --add-dir/workspace-write), profile re-allows ONLY the install dir and denies the real Codex home" $ok "rc=$rc row: $(cut -c1-160 "$tmp/r14t.jsonl" 2>&1) argv: $(tr '\n' '|' <"$cav" 2>/dev/null)"
fi
if darwin_only 14u; then
# the REAL codex must START under the generated profile (--version, no model call): the adapter's resolution is replayed against seatbelt.py
if cx="$(command -v codex)" && [[ -n "$cx" ]]; then
  vroot="$tmp/ucell"; mkdir -p "$vroot/work" "$vroot/home"; xreal="$(rprobe "$cx")"; xbin="$(dirname "$xreal")"; xhome="${EVAL_CODEX_REAL_HOME:-$HOME/.codex}"
  case "$xbin" in "$(rprobe "$xhome")"/*) xflag=--reallow-read ;; *) xflag=--allow-read ;; esac
  python3 -I -B "$here/lib/seatbelt.py" "$vroot/work" "$vroot/home" "$vroot/gocache" "$vroot/tmp" read-only "$xflag" "$xbin" \
    --deny-read "$(cd "$here/../.." && pwd)" --deny-read "$xhome" >"$vroot/p.sb"; prc=$?
  vout="$( (cd "$vroot/work" && env -i PATH="$PATH" HOME="$vroot/home" CODEX_HOME="$vroot/home" TMPDIR="$vroot/tmp" /usr/bin/sandbox-exec -f "$vroot/p.sb" "$xreal" --version) 2>&1)"; vrc=$?
  if [[ $prc -eq 0 && $vrc -eq 0 && "$vout" == *codex-cli* ]]; then ok=0; else ok=1; fi
  note "14u the real codex binary starts under the generated profile (codex --version exits 0)" $ok "prc=$prc vrc=$vrc out: $(echo "$vout" | head -c 200)"
else
  printf '  SKIP  14u (no codex on PATH; not counted)\n'
fi
fi
if darwin_only 14v; then
# credential lifecycle under the profile: the sandboxed process rotates the copy in its home; the write-back and the scrub still happen
cp "$CXR/auth.json" "$tmp/cxauth.orig"; : >"$frec/rotate-cx"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
rm -f "$frec/rotate-cx"; perm="$(python3 -I -B -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$CXR/auth.json")"
if [[ $arc -eq 0 && ! -e "$AH/auth.json" && "$(cat "$CXR/auth.json")" == *ROTATED-CX* && "$perm" == 0o600 && -z "$(find "$CXR" -name '.auth.*' | head -1)" ]]; then ok=0; else ok=1; fi
cp "$tmp/cxauth.orig" "$CXR/auth.json"
note "14v codex under the profile: a token rotated by the sandboxed process is written back (600) and the copy scrubbed" $ok "rc=$arc perm=$perm $(head -c 200 "$tmp/adapter.err")"
fi
# 14w-14z: no usable sandbox (both platforms: fake uname / PATH without sandbox-exec)
CXSB=1 adapter codex read-only CODEX_API_KEY=k PATH="$fu:$fb:$PATH"; arc=$?
if [[ $arc -eq 79 && ! -e "$frec/codex.argv" && ! -e "$AH/auth.json" && "$(cat "$tmp/adapter.err")" == *"macOS-only"* ]]; then ok=0; else ok=1; fi
note "14w codex, non-Darwin (fake uname=Linux), no opt-out: exit 79, host never starts, no credential staged" $ok "rc=$arc $(head -c 160 "$tmp/adapter.err")"
runcodex "$good" "$tmp/r14w.jsonl" PATH="$fu:$fb:$PATH"; rc=$?
if [[ $rc -eq 3 && "$(rowval "$tmp/r14w.jsonl" error)" == sandbox && "$(rowval "$tmp/r14w.jsonl" pass)" == false ]]; then ok=0; else ok=1; fi
note "14x codex non-Darwin through run.sh: row error:sandbox, pass:false, exit 3" $ok "rc=$rc row: $(cut -c1-200 "$tmp/r14w.jsonl" 2>&1)"
adapter codex read-only CODEX_API_KEY=k EVAL_NO_SANDBOX=1 PATH="$fu:$fb:$PATH"; arc=$?; wtxt="$(cat "$tmp/adapter.err")"
runcodex "$good" "$tmp/r14y.jsonl" EVAL_NO_SANDBOX=1 PATH="$fu:$fb:$PATH"; rc=$?; cav="$(find "$KC" -name codex.argv | head -1)"
[[ -n "$cav" ]] || cav="$frec/codex.argv"
if [[ $arc -eq 0 && "$wtxt" == *WARNING*"READS ARE NOT"* && $rc -eq 0 && "$(rowval "$tmp/r14y.jsonl" sandbox)" == codex && "$(rowval "$tmp/r14y.jsonl" error)" != sandbox \
   && "$(cat "$tmp/runcodex.err")" == *"reads are unconfined"* && "$(argafter "$frec/codex.argv" -s)" == workspace-write ]] && ! grep -q danger-full-access "$frec/codex.argv"; then ok=0; else ok=1; fi
note "14y codex non-Darwin + EVAL_NO_SANDBOX=1: runs under Codex's own -s workspace-write, row sandbox:codex, warnings on stderr (reads unconfined)" $ok "arc=$arc rc=$rc row: $(cut -c1-300 "$tmp/r14y.jsonl" 2>&1) argv-s: $(argafter "$frec/codex.argv" -s)"
CXSB=1 adapter codex read-only CODEX_API_KEY=k EVAL_NO_SANDBOX=0 PATH="$fb:$nosb"; arc=$?
if [[ $arc -eq 79 && ! -e "$frec/codex.argv" && ! -e "$AH/auth.json" ]]; then ok=0; else ok=1; fi
note "14z codex with no sandbox-exec on PATH: exit 79, host never starts (no silent unconfined run)" $ok "rc=$arc $(head -c 160 "$tmp/adapter.err")"
# ---- 14q2 / 14u2: metadata-only access to the ancestors of the cell (CLIs canonicalise their home) ----
if darwin_only 14q2; then
ad="$tmp/anc14"; mkdir -p "$ad/cell/work"; echo SIB >"$ad/sibling-file"; echo SIB2 >"$ad/cell/sibling2"
python3 -I -B "$here/lib/seatbelt.py" "$ad/cell/work" "$ad/cell/home" "$ad/cell/gc" "$ad/cell/tmp" read-only --deny-root "$tmp" >"$ad/p.sb"; prc=$?
sbt() { /usr/bin/sandbox-exec -f "$ad/p.sb" "$@" >/dev/null 2>&1 && echo ok || echo denied; }
r1="$(sbt /usr/bin/stat "$ad")"; r2="$(sbt /bin/ls "$ad")"; r3="$(sbt /bin/cat "$ad/sibling-file")"; r4="$(sbt /usr/bin/stat "$ad/sibling-file")"; r5="$(sbt /bin/cat "$ad/cell/sibling2")"
if [[ $prc -eq 0 && "$r1" == ok && "$r2" == denied && "$r3" == denied && "$r4" == denied && "$r5" == denied ]] && grep -q '^(allow file-read-metadata (literal ' "$ad/p.sb" && ! grep '^(allow file-read-metadata' "$ad/p.sb" | grep -q subpath; then ok=0; else ok=1; fi
note "14q2 ancestors of the cell: stat works, but ls, cat of a sibling file and stat of a sibling file are all denied (metadata rule is literals only)" $ok "prc=$prc stat=$r1 ls=$r2 cat-sibling=$r3 stat-sibling=$r4 cat-sibling-of-cell=$r5"
fi
if darwin_only 14u2; then
# the REAL `codex exec` must get past its start (no credential, no model call): its first event or its auth error, never `Operation not permitted`
if cx="$(command -v codex)" && [[ -n "$cx" ]]; then
  u2fail=""; u2tmp="$(mktemp -d /tmp/eval-u2.XXXXXX)"   # a /var/folders path AND a path through the symlinked /tmp (not its realpath)
  for vroot in "$tmp/u2cell" "$u2tmp/u2cell"; do
  mkdir -p "$vroot/work" "$vroot/home"; xreal="$(rprobe "$cx")"; xbin="$(dirname "$xreal")"; xhome="${EVAL_CODEX_REAL_HOME:-$HOME/.codex}"
  case "$xbin" in "$(rprobe "$xhome")"/*) xflag=--reallow-read ;; *) xflag=--allow-read ;; esac
  python3 -I -B "$here/lib/seatbelt.py" "$vroot/work" "$vroot/home" "$vroot/gocache" "$vroot/tmp" read-only "$xflag" "$xbin" \
    --deny-read "$(cd "$here/../.." && pwd)" --deny-read "$xhome" >"$vroot/p.sb"; prc=$?
  echo hi >"$vroot/prompt"
  uout="$(cd "$vroot/work" && env -i PATH="$PATH" HOME="$vroot/home" CODEX_HOME="$vroot/home" TMPDIR="$vroot/tmp" PF="$vroot/prompt" python3 -I -B -c '
import os, subprocess, sys, threading
p = subprocess.Popen(sys.argv[1:], stdin=open(os.environ["PF"]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
t = threading.Timer(20, p.kill); t.start()
first = p.stdout.readline(); p.kill(); t.cancel()
try: err = p.communicate(timeout=3)[1]
except Exception: err = ""
print(first.strip()); print(err.strip()[:300])' /usr/bin/sandbox-exec -f "$vroot/p.sb" "$xreal" exec --json --skip-git-repo-check --ignore-user-config -C "$vroot/work" --ephemeral -s danger-full-access -c approval_policy=never - 2>&1)"
  if [[ $prc -ne 0 || "$uout" != *thread.started* || "$uout" == *"Operation not permitted"* ]]; then u2fail="$u2fail [$vroot: prc=$prc $(echo "$uout" | head -c 200)]"; fi
  done
  rm -rf "$u2tmp"
  if [[ -z "$u2fail" ]]; then ok=0; else ok=1; fi
  note "14u2 the real codex exec starts under the generated profile with a no-credential home, home under /var/folders and under /tmp (first event printed, no 'Operation not permitted')" $ok "$u2fail"
else
  printf '  SKIP  14u2 (no codex on PATH; not counted)\n'
fi
fi
# neutral opt-out name on the Claude host (the alias EVAL_CLAUDE_NO_SANDBOX is 15d/15g)
adapter claude read-only "$TOK" EVAL_CLAUDE_NO_SANDBOX=0 EVAL_NO_SANDBOX=1; arc=$?; th="$AH/claude.touch"
if [[ $arc -eq 0 ]] && grep -qx 'outside=written' "$th" && grep -q 'WARNING.*UNCONFINED' "$tmp/adapter.err"; then ok=0; else ok=1; fi
rm -f "$tmp/outside/canary"
note "15d2 EVAL_NO_SANDBOX=1 (neutral name) on the claude adapter: runs unconfined WITH a loud stderr warning" $ok "rc=$arc touch: $(tr '\n' ' ' <"$th" 2>&1)"
runclaude "$good" "$tmp/r15d2.jsonl" EVAL_CLAUDE_NO_SANDBOX=0 EVAL_NO_SANDBOX=1
if [[ "$(rowval "$tmp/r15d2.jsonl" sandbox)" == off && "$(cat "$tmp/runclaude.err")" == *UNCONFINED* ]]; then ok=0; else ok=1; fi
note "15g2 EVAL_NO_SANDBOX=1 through run.sh on the claude host: row sandbox:off and a warning" $ok "sandbox=$(rowval "$tmp/r15d2.jsonl" sandbox)"
# W2: nothing under benchmarks/eval evaluates an environment value as code
hits="$(grep -rnE 'bash -c "\$|(^|[;&| (])eval ' "$here" --include='*.sh' --exclude-dir=corpus --exclude=selftest.sh | grep -v '^[^:]*:[0-9]*: *#' || true)"
if [[ -z "$hits" ]]; then ok=0; else ok=1; fi
note "15j no env value is run as code (bash -c \"\$...\" / eval) under benchmarks/eval" $ok "$hits"

# ---- 16: N2 N4 N8 + W1 W4 W5 -------------------------------------------------------
# N2: the real auth.json changed during the run -> a rotated copy must NOT overwrite it
: >"$frec/rotate"; : >"$frec/changereal"; echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
adapter codex read-only; arc=$?
rm -f "$frec/rotate" "$frec/changereal"
if [[ $arc -eq 0 && "$(cat "$realcodex/auth.json")" == *OTHER-PROCESS-CANARY* && ! -e "$AH/auth.json" ]]; then ok=0; else ok=1; fi
note "16a codex: no write-back when the real auth.json changed since the copy (copy still scrubbed)" $ok "real now: $(cat "$realcodex/auth.json")"
echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
# N2b: the real file changed to a SAME-LENGTH, same-prefix variant: only a full-content digest sees it
: >"$frec/rotate"; : >"$frec/changesame"; echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
adapter codex read-only; arc=$?
rm -f "$frec/rotate" "$frec/changesame"
if [[ $arc -eq 0 && "$(cat "$realcodex/auth.json")" == *ORIG-CANAXX* && ! -e "$AH/auth.json" ]]; then ok=0; else ok=1; fi
note "16a2 codex: a same-length edit of the real auth.json is still detected (digest of the whole file)" $ok "real now: $(cat "$realcodex/auth.json")"
echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
# N8: the preflight says missing when there is no credential
emptyc="$tmp/emptyc"; mkdir -p "$emptyc" "$tmp/emptyx"
out1="$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN PATH="$fb:$PATH" HOME="$realhome" EVAL_CLAUDE_AUTH_DIR="$emptyc" bash "$here/lib/authcheck.sh" claude 2>&1)"; rc1=$?
out2="$(env -u CODEX_API_KEY HOME="$realhome" EVAL_CODEX_REAL_HOME="$tmp/emptyx" bash "$here/lib/authcheck.sh" codex 2>&1)"; rc2=$?
out3="$(env -u CODEX_API_KEY HOME="$realhome" EVAL_CODEX_REAL_HOME="$realcodex" bash "$here/lib/authcheck.sh" codex 2>&1)"; rc3=$?
out4="$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN PATH="$fb:$PATH" HOME="$realhome" EVAL_CLAUDE_AUTH_DIR="$realclaude" bash "$here/lib/authcheck.sh" claude 2>&1)"; rc4=$?
if [[ $rc1 -eq 78 && $out1 == missing && $rc2 -eq 78 && $out2 == missing && $rc3 -eq 0 && $out3 == ok && $rc4 -eq 0 && $out4 == ok ]]; then ok=0; else ok=1; fi
note "16b authcheck: missing -> exit 78, present -> ok (claude and codex)" $ok "claude-empty=$rc1/$out1 codex-empty=$rc2/$out2 codex-ok=$rc3/$out3 claude-ok=$rc4/$out4"
# live loop: preflight refuses; a host that loses auth stops the loop after the first cell (N4)
lc="$tmp/livecorp"; ld="$tmp/liveres"; mktask "$lc" prod-review t-live dev good >/dev/null
live() { env EVAL_LIVE=1 EVAL_CORPUS="$lc" EVAL_RESULTS_DIR="$ld" EVAL_SKILLS_ROOT="$skills" HOME="$realhome" "$@" bash "$here/lib/live.sh" >"$tmp/live.out" 2>"$tmp/live.err"; }
rm -rf "$ld"; live EVAL_HOSTS=codex EVAL_CODEX_REAL_HOME="$tmp/emptyx" N=1; rc=$?
if [[ $rc -eq 2 && -z "$(find "$ld" -name '*.jsonl' 2>/dev/null | head -1)" && "$(cat "$tmp/live.err")" == *"no usable credential"* ]]; then ok=0; else ok=1; fi
note "16c live preflight refuses before spending when a host has no credential" $ok "rc=$rc $(head -c 200 "$tmp/live.err")"
rm -rf "$ld"; live EVAL_HOSTS=stub STUB_MODE=noauth N=3; rc=$?
nr="$(cat "$ld"/*.jsonl 2>/dev/null | grep -c . || true)"
if [[ $rc -eq 3 && "$nr" == 1 ]]; then ok=0; else ok=1; fi
note "16d live loop stops after the FIRST cell on an auth failure and exits non-zero" $ok "rc=$rc rows=$nr"
# W4: arm order is shuffled per (task, host, rep), seed stored, one fresh file per run
rm -rf "$ld"; live EVAL_HOSTS=stub STUB_MODE=noop EVAL_SEED=7 N=6; rc=$?
f1="$(find "$ld" -name '*.jsonl' | head -1)"
python3 -I -B - "$f1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
firsts = [rows[i]["arm"] for i in range(0, len(rows), 2)]
ok = len(rows) == 12 and set(firsts) == {"skill", "bare"} and all(r["order_seed"] == "7" for r in rows)
sys.exit(0 if ok else 1)
PY
r=$?
base="$(basename "$f1")"
if [[ $rc -eq 0 && $r -eq 0 && "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z- ]]; then ok=0; else ok=1; fi
note "16e live: arm order varies per rep, order_seed in every row, file named <date>T<HHMMSS>Z-<sha>" $ok "rc=$rc file=$base $(head -c 200 "$tmp/live.err")"
# 16e was flaky (1/32) while the order was keyed by the temp corpus PATH: the same seed must give the same order under any root
armseq() { python3 -I -B -c 'import json,sys
print(" ".join(r["arm"] for r in map(json.loads, open(sys.argv[1])) if r))' "$1"; }
s1="$(armseq "$f1")"
lc2="$tmp/livecorp2/deeper"; mktask "$lc2" prod-review t-live dev good >/dev/null; ld2="$tmp/liveres2"
live EVAL_CORPUS="$lc2" EVAL_RESULTS_DIR="$ld2" EVAL_HOSTS=stub STUB_MODE=noop EVAL_SEED=7 N=6
s2="$(armseq "$(find "$ld2" -name '*.jsonl' | head -1)")"
if [[ -n "$s1" && "$s1" == "$s2" ]]; then ok=0; else ok=1; fi
note "16e2 live: the same seed gives the same arm order under a different corpus root" $ok "a=$s1 b=$s2"
live EVAL_HOSTS=stub STUB_MODE=noop EVAL_SEED=7 N=1; nf="$(find "$ld" -name '*.jsonl' | wc -l | tr -d ' ')"
if [[ "$nf" == 2 ]]; then ok=0; else ok=1; fi
note "16f a second live run writes its own file (no duplicate reps appended)" $ok "files=$nf"
# W1: five tasks, skill 1/3 vs bare 0/3 on each -> the interval must not collapse to a point
python3 -I -B - "$tmp/w1.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as o:
    for t in range(5):
        for rep, sp in enumerate((True, False, False)):
            for arm, ok in (("skill", sp), ("bare", False)):
                o.write(json.dumps({"task": "t%d" % t, "skill": "prod-spec", "split": "heldout", "kind": "seeded", "arm": arm, "host": "claude",
                                    "model": "m", "rep": rep, "pass": ok, "metrics": {}}) + "\n")
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w1.jsonl" 2>&1 | grep -E '^prod-spec +claude +m +n/a +heldout +seeded +\+' || true)"
# Two-level bootstrap on this data gives about [+13, +60] (task-only resampling would print [+33.3, +33.3]).
# The whole interval is above 0 -- every task shows the skill ahead -- so the verdict is "helps", but wide.
if [[ "$l" == *"+33.3 pp"* && "$l" != *"[+33.3, +33.3]"* && "$l" == *"[+1"* && "$l" == *helps ]]; then ok=0; else ok=1; fi
note "16g report: within-task rep noise widens the interval (no zero-width [+33.3, +33.3])" $ok "$l"
# W5: rows without usage are excluded from the token figure and counted, never 0
python3 -I -B - "$tmp/w5.jsonl" <<'PY'
import json, sys
rows = [{"task": "a", "tokens_in": 100, "tokens_out": 50}, {"task": "b"}, {"task": "c", "tokens_in": None, "tokens_out": None}]
with open(sys.argv[1], "w") as o:
    for r in rows:
        r.update({"skill": "prod-ops", "split": "dev", "kind": "seeded", "arm": "skill", "host": "codex", "model": "m", "rep": 1, "pass": True, "metrics": {}})
        o.write(json.dumps(r) + "\n")
    for r in rows[:1]:
        pass
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w5.jsonl" 2>&1 | grep -E '^prod-ops +codex +m +n/a +dev +seeded +skill ' || true)"
if [[ "$l" == *"150 (2 no usage)"* ]]; then ok=0; else ok=1; fi
note "16h report: rows with no usage are excluded from the token mean and counted" $ok "$l"
python3 -I -B - "$tmp/w5b.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as o:
    o.write(json.dumps({"task": "a", "skill": "prod-ops", "split": "dev", "kind": "seeded", "arm": "skill", "host": "codex", "model": "m", "rep": 1, "pass": True, "metrics": {}}) + "\n")
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w5b.jsonl" 2>&1 | grep -E '^prod-ops +codex +m +n/a +dev +seeded +skill ' || true)"
if [[ "$l" == *"n/a (1 no usage)"* ]]; then ok=0; else ok=1; fi
note "16i report: all rows without usage -> n/a" $ok "$l"
# sandbox modes are never pooled
python3 -I -B - "$tmp/sbx.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as o:
    for sb in ("seatbelt", "off"):
        for arm in ("skill", "bare"):
            o.write(json.dumps({"task": "a", "skill": "prod-ops", "split": "dev", "kind": "seeded", "arm": arm, "host": "claude", "model": "m", "sandbox": sb, "rep": 1, "pass": True, "metrics": {}}) + "\n")
PY
out="$(python3 -I -B "$here/report.py" "$tmp/sbx.jsonl" 2>&1)"
if [[ "$(echo "$out" | grep -cE '^prod-ops +claude +m +seatbelt +dev +seeded +skill ')" == 1 && "$(echo "$out" | grep -cE '^prod-ops +claude +m +off +dev +seeded +skill ')" == 1 ]]; then ok=0; else ok=1; fi
note "16j report: rows with different sandbox values are never pooled" $ok "$(echo "$out" | head -6 | tr '\n' '|')"

# ---- 18: per-kind reports (seeded recall vs clean false-positive control) --------------------
mkkinds() { # mkkinds <file> <n-seeded-tasks> <n-clean-tasks>: skill WINS on seeded, LOSES on clean, 2 reps per arm
python3 -I -B - "$1" "$2" "$3" <<'PY'
import json, sys
f, ns, nc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(f, "w") as o:
    for kind, n in (("seeded", ns), ("clean", nc)):
        for t in range(n):
            for rep in (1, 2):
                for arm in ("skill", "bare"):
                    win = (arm == "skill") == (kind == "seeded")   # seeded: skill passes; clean: bare passes
                    o.write(json.dumps({"task": "%s%d" % (kind[0], t), "skill": "prod-review", "split": "heldout", "kind": kind, "arm": arm,
                                        "host": "claude", "model": "m", "rep": rep, "pass": win,
                                        "metrics": {"found": 2 if arm == "skill" else 1, "false_positives": 0 if win else 1}}) + "\n")
PY
}
verdict_lines() { grep -E '(helps|hurts|no evidence|insufficient tasks)' | grep -v '^WARNING' || true; }
mkkinds "$tmp/k1.jsonl" 6 6; out="$(python3 -I -B "$here/report.py" "$tmp/k1.jsonl" 2>&1)"
l1="$(echo "$out" | grep -E '^recall \(seeded\)' || true)"; l2="$(echo "$out" | grep -E '^false-positive control \(clean\)' || true)"
if [[ "$l1" == *helps && "$l2" == *hurts ]]; then r=0; else r=1; fi
note "18a skill wins on seeded and LOSES on clean -> recall line helps, false-positive line hurts" "$r" "$l1 // $l2"
vl="$(echo "$out" | verdict_lines)"; nv="$(echo "$vl" | grep -c . || true)"; nk="$(echo "$vl" | grep -cE 'seeded|clean' || true)"
d1="$(echo "$vl" | grep -E '^prod-review +claude +m +n/a +heldout +seeded ' || true)"; d2="$(echo "$vl" | grep -E '^prod-review +claude +m +n/a +heldout +clean ' || true)"
if [[ "$nv" == 4 && "$nk" == 4 && "$d1" == *helps && "$d2" == *hurts ]]; then r=0; else r=1; fi
note "18b no pooled verdict: exactly 4 verdict lines (2 kinds x diff row + named line), every one names its kind" "$r" "n=$nv named=$nk // $vl"
mkkinds "$tmp/k2.jsonl" 3 6; out="$(python3 -I -B "$here/report.py" "$tmp/k2.jsonl" 2>&1)"
l1="$(echo "$out" | grep -E '^recall \(seeded\)' || true)"; l2="$(echo "$out" | grep -E '^false-positive control \(clean\)' || true)"
if [[ "$l1" == *"insufficient tasks (n=3)" && "$l2" != *insufficient* && "$l2" == *hurts ]]; then r=0; else r=1; fi
note "18c <5 paired seeded tasks but 6 clean: 'insufficient tasks' on the seeded line ONLY" "$r" "$l1 // $l2"
l="$(echo "$out" | grep -E '^prod-review +claude +m +n/a +heldout +seeded +skill ' || true)"
if [[ "$l" =~ [[:space:]]0\.00[[:space:]]+2\.00$ ]]; then r=0; else r=1; fi
note "18d report: mean false_positives and found per row printed per arm and kind (seeded skill: 0.00 / 2.00)" "$r" "$l"
{ head -n 1 "$tmp/k1.jsonl"; sed 1d "$tmp/k1.jsonl" | head -n 1 | python3 -I -B -c 'import json,sys; r=json.loads(sys.stdin.read()); del r["kind"]; print(json.dumps(r))'; } >"$tmp/nokind.jsonl"
msg="$(python3 -I -B "$here/report.py" "$tmp/nokind.jsonl" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -ne 0 && "$msg" == *"nokind.jsonl:2:"* && "$msg" == *kind* ]]; then r=0; else r=1; fi
note "18e a row without kind -> non-zero exit naming file:line (no silent default)" "$r" "rc=$rc $msg"
python3 -I -B "$here/report.py" "$tmp/k1.jsonl" >"$tmp/k.a" 2>&1; python3 -I -B "$here/report.py" "$tmp/k1.jsonl" >"$tmp/k.b" 2>&1
cmp -s "$tmp/k.a" "$tmp/k.b"; r=$?
note "18f kinds report: same seed twice -> identical output" "$r" "outputs differ"

# ---- 19: the output schema mechanism, the row, lint ---------------------------------------------
sch="$tmp/schema/output.schema.json"; mkdir -p "$tmp/schema"
printf '{\n  "type": "object",\n  "properties": {"findings": {"type": "array"}},\n  "required": ["findings"]\n}\n' >"$sch"
compact='{"type":"object","properties":{"findings":{"type":"array"}},"required":["findings"]}'
ADAPTER_SCHEMA="$sch" adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; arc=$?; av="$AH/claude.argv"
if [[ $arc -eq 0 && "$(argafter "$av" --json-schema)" == "$compact" ]]; then ok=0; else ok=1; fi
note "19a claude with a schema file: --json-schema <the schema as one line of JSON>" $ok "rc=$arc $(tr '\n' '|' <"$av")"
adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; arc=$?; av="$AH/claude.argv"
if [[ $arc -eq 0 ]] && ! grep -qx -- --json-schema "$av"; then ok=0; else ok=1; fi
note "19b claude without a schema file: no --json-schema" $ok "rc=$arc $(tr '\n' '|' <"$av")"
ADAPTER_SCHEMA="$sch" adapter codex read-only CODEX_API_KEY=k; arc=$?; xv="$frec/codex.argv"
if [[ $arc -eq 0 && "$(argafter "$xv" --output-schema)" == "$sch" && "$(argafter "$xv" -o)" == "$AH/.eval-codex-last.txt" ]]; then ok=0; else ok=1; fi
note "19c codex with a schema file: --output-schema <that path> and -o <last-message file>" $ok "rc=$arc $(tr '\n' '|' <"$xv")"
adapter codex read-only CODEX_API_KEY=k; arc=$?; xv="$frec/codex.argv"
if [[ $arc -eq 0 ]] && ! grep -qx -- --output-schema "$xv" && ! grep -qx -- -o "$xv"; then ok=0; else ok=1; fi
note "19d codex without a schema file: neither --output-schema nor -o" $ok "rc=$arc $(tr '\n' '|' <"$xv")"
jdoc() { python3 -I -B -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$1" 2>/dev/null || echo "<not json>"; }
echo '{"result":"prose that must lose","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2},"structured_output":{"findings":[{"id":1}]}}' >"$frec/claude.out"
ADAPTER_SCHEMA="$sch" adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; arc=$?
if [[ $arc -eq 0 && "$(jdoc "$tmp/aout.txt")" == '{"findings": [{"id": 1}]}' ]]; then ok=0; else ok=1; fi
note "19e claude result with structured_output: the output file is exactly that document (not the result prose)" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
echo '{"result":"{\"findings\":[{\"id\":2}]}","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2}}' >"$frec/claude.out"
ADAPTER_SCHEMA="$sch" adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; arc=$?
if [[ $arc -eq 0 && "$(cat "$tmp/aout.txt")" == '{"findings":[{"id":2}]}' ]]; then ok=0; else ok=1; fi
note "19f claude result text that is JSON, no structured field: the output file is that text, unchanged" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
echo '{"result":"just prose","is_error":false,"structured_output":null,"usage":{}}' >"$frec/claude.out"
ADAPTER_SCHEMA="$sch" adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; arc=$?
if [[ $arc -eq 0 && "$(cat "$tmp/aout.txt")" == "just prose" ]]; then ok=0; else ok=1; fi
note "19g claude prose, structured_output null: the prose is passed through (the row will say output_valid:false)" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
rm -f "$frec/claude.out"
printf '%s\n' '{"findings":[{"id":3}]}' >"$frec/codex.last"
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"jsonl text that must lose"}}' >"$frec/codex.jsonl"
ADAPTER_SCHEMA="$sch" adapter codex read-only CODEX_API_KEY=k; arc=$?
if [[ $arc -eq 0 && "$(jdoc "$tmp/aout.txt")" == '{"findings": [{"id": 3}]}' ]]; then ok=0; else ok=1; fi
note "19h codex: the -o last-message file is the document (preferred over the JSONL item)" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
rm -f "$frec/codex.last"; printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"findings\":[{\"id\":4}]}"}}' >"$frec/codex.jsonl"
ADAPTER_SCHEMA="$sch" adapter codex read-only CODEX_API_KEY=k; arc=$?
if [[ $arc -eq 0 && "$(jdoc "$tmp/aout.txt")" == '{"findings": [{"id": 4}]}' ]]; then ok=0; else ok=1; fi
note "19i codex: no -o file written -> the last agent_message of the JSONL is the document" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
rm -f "$frec/codex.jsonl"
# stdin: the caller's stdin is a pipe that never closes; codex must still get the prompt and end
mkfifo "$tmp/hang.fifo"; sleep 60 >"$tmp/hang.fifo" & holder=$!
: >"$frec/stdincheck"
ADAPTER_SCHEMA="$sch" adapter codex read-only CODEX_API_KEY=k <"$tmp/hang.fifo"; arc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -f "$frec/stdincheck" "$tmp/hang.fifo"
if [[ $arc -eq 0 && "$(cat "$frec/codex.stdin" 2>&1)" == "do the thing" ]] && grep -qx -- - "$frec/codex.argv"; then ok=0; else ok=1; fi
note "19j codex: stdin is the prompt FILE (arg '-'), never the caller's never-closing pipe: no hang" $ok "rc=$arc stdin saw: $(cat "$frec/codex.stdin" 2>&1)"

# the row, through run.sh (stub host) with a corpus whose skill has a schema
scorp="$tmp/scorp"; jt="$(mktask "$scorp" prod-review t-js heldout jsonobj)"; mkdir -p "$scorp/prod-review/_lib"; cp "$sch" "$scorp/prod-review/_lib/output.schema.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "I found a bug in the handler." >"$2"\n' >"$tmp/prose.sh"
r="$tmp/r19a.jsonl"; cell "$r" "$jt" skill solve
if [[ "$(rowval "$r" output_valid)" == true && "$(rowval "$r" pass)" == true && "$(rowval "$r" kind)" == seeded ]]; then ok=0; else ok=1; fi
note "19k schema applies, agent writes a JSON object -> row output_valid:true, kind from task.json, pass:true" $ok "row: $(cut -c1-300 "$r" 2>&1)"
r="$tmp/r19b.jsonl"; cell "$r" "$jt" skill solve STUB_SOLVE_CMD="$tmp/prose.sh"
if [[ "$(nrows "$r")" == 1 && "$(rowval "$r" output_valid)" == false && "$(rowval "$r" pass)" == false && "$(rowval "$r" metrics)" == *"'found': 0"* ]]; then ok=0; else ok=1; fi
note "19l host returns prose -> a row exists, output_valid:false, pass:false, the grader still ran" $ok "row: $(cut -c1-300 "$r" 2>&1)"
r="$tmp/r19c.jsonl"; cell "$r" "$jt" skill noop
if [[ "$(nrows "$r")" == 1 && "$(rowval "$r" output_valid)" == false && "$(rowval "$r" pass)" == false ]]; then ok=0; else ok=1; fi
note "19m host returns nothing -> a row exists, output_valid:false, pass:false" $ok "row: $(cut -c1-300 "$r" 2>&1)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "[1,2]" >"$2"\n' >"$tmp/array.sh"
r="$tmp/r19d.jsonl"; cell "$r" "$jt" skill solve STUB_SOLVE_CMD="$tmp/array.sh"
if [[ "$(rowval "$r" output_valid)" == false ]]; then ok=0; else ok=1; fi
note "19n valid JSON that is not an OBJECT (an array) -> output_valid:false" $ok "row: $(cut -c1-300 "$r" 2>&1)"
r="$tmp/r19e.jsonl"; cell "$r" "$good" skill solve
if [[ "$(rowval "$r" output_valid)" == None && "$(rowval "$r" kind)" == seeded ]]; then ok=0; else ok=1; fi
note "19o no schema for the skill -> output_valid:null" $ok "row: $(cut -c1-300 "$r" 2>&1)"
ck="$(TASK_KIND=clean mktask "$tmp/kcorp" prod-review t-clean heldout good)"; r="$tmp/r19f.jsonl"; cell "$r" "$ck" skill solve
if [[ "$(rowval "$r" kind)" == clean ]]; then ok=0; else ok=1; fi
note "19p row kind is copied from task.json (clean)" $ok "row: $(cut -c1-300 "$r" 2>&1)"
# through run.sh with the FAKE hosts: the 9th adapter argument really carries the schema
echo '{"result":"x","is_error":false,"usage":{},"structured_output":{"found":1,"findings":[]}}' >"$frec/claude.out"
runclaude "$jt" "$tmp/r19g.jsonl"
if [[ "$(rowval "$tmp/r19g.jsonl" output_valid)" == true && "$(rowval "$tmp/r19g.jsonl" pass)" == true && "$(argafter "$(find "$KT" -name claude.argv | head -1)" --json-schema)" == "$compact" ]]; then ok=0; else ok=1; fi
note "19q run.sh -> claude adapter: schema passed, structured document graded, row output_valid:true" $ok "row: $(cut -c1-300 "$tmp/r19g.jsonl" 2>&1)"
rm -f "$frec/claude.out"
printf '%s\n' '{"found":1,"findings":[]}' >"$frec/codex.last"
env CODEX_API_KEY=k EVAL_NO_SANDBOX=1 PATH="$fb:$PATH" HOME="$realhome" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$jt" --arm bare --host codex --rep 1 --out "$tmp/r19h.jsonl" >/dev/null 2>&1; rc=$?
rm -f "$frec/codex.last"
if [[ $rc -eq 0 && "$(rowval "$tmp/r19h.jsonl" output_valid)" == true && "$(rowval "$tmp/r19h.jsonl" pass)" == true && "$(argafter "$frec/codex.argv" --output-schema)" == "$(cd "$scorp" && pwd)/prod-review/_lib/output.schema.json" ]]; then ok=0; else ok=1; fi
note "19r run.sh -> codex adapter: --output-schema is the skill's _lib/output.schema.json, -o document graded" $ok "rc=$rc row: $(cut -c1-300 "$tmp/r19h.jsonl" 2>&1)"
# lint
mktask "$tmp/l-nokind" prod-review t-nokind heldout good >/dev/null
python3 -I -B - "$tmp/l-nokind/prod-review/t-nokind/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); del t["kind"]; json.dump(t, open(sys.argv[1], "w"))
PY
lint_case "19s lint RED on a task.json without kind" "$tmp/l-nokind" 1 "missing key 'kind'"
mktask "$tmp/l-emptykind" prod-review t-ek heldout good >/dev/null
sed 's/"kind":"seeded"/"kind":" "/' "$tmp/l-emptykind/prod-review/t-ek/task.json" >"$tmp/ek.json" && cp "$tmp/ek.json" "$tmp/l-emptykind/prod-review/t-ek/task.json"
lint_case "19t lint RED on a blank kind" "$tmp/l-emptykind" 1 "key 'kind' has the wrong type"
REF_OUT="the reference wrote prose" mktask "$tmp/l-sbad" prod-review t-sb heldout jsonobj >/dev/null; mkdir -p "$tmp/l-sbad/prod-review/_lib"; cp "$sch" "$tmp/l-sbad/prod-review/_lib/"
lint_case "19u lint RED when the reference output is not a JSON object under a schema" "$tmp/l-sbad" 1 "did not write a JSON object"
mktask "$tmp/l-sok" prod-review t-so heldout jsonobj >/dev/null; mkdir -p "$tmp/l-sok/prod-review/_lib"; cp "$sch" "$tmp/l-sok/prod-review/_lib/"
lint_case "19v lint GREEN: schema present, reference writes a JSON object, kind set" "$tmp/l-sok" 0 "lint: ok"

# ---- 20: no bytecode litter outside the corpus -----------------------------------------------------
pyc="$(find "$here" -name __pycache__ -not -path "$here/corpus/*" 2>/dev/null | head -3 | tr '\n' ' ')"
if [[ -z "$pyc" ]]; then ok=0; else ok=1; fi
note "20 no __pycache__ under benchmarks/eval outside corpus/ after the run" $ok "found: $pyc"

# darwin-only accounting: skipped cases are never counted as passed and never silent
sorted_ids() { printf '%s\n' "$@" | grep . | sort | tr '\n' ' ' || true; }
want="$(sorted_ids $DARWIN_ONLY_DECLARED)"; seen="$(sorted_ids $DO_SEEN)"; skipped="$(sorted_ids $DO_SKIPPED)"
if [[ "$PLATFORM" == Darwin ]]; then wskip=""; else wskip="$want"; fi
if [[ "$seen" == "$want" && "$skipped" == "$wskip" ]]; then ok=0; else ok=1; fi
note "17 darwin-only accounting: declared [$want] seen [$seen] skipped [$skipped] (platform $PLATFORM expects skipped [$wskip])" $ok "declared=[$want] seen=[$seen] skipped=[$skipped] expected-skipped=[$wskip]"
nskip=$(printf '%s\n' $DO_SKIPPED | grep -c . || true)
if (( total == 0 )); then echo "selftest: FAIL -- no case ran; nothing checked is not a pass" >&2; exit 2; fi
echo "selftest: $pass/$total ok, $nskip skipped (darwin-only)"
[[ $pass -eq $total ]]
