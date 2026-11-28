#!/usr/bin/env bash
# selftest.sh -- the harness proves itself, hermetically (no network, no model,
# < 60 s). Every guarded property is shown RED on a fixture where it is false
# and GREEN where it holds; a gate that cannot go red is not a gate.
#
# Exit: 0 every case passed | 1 a case failed | 2 no case ran
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HERMETIC FROM THE FIRST LINE: the suite root is created here (the ONE use of the caller's TMPDIR, a mktemp and nothing else) and
# TMPDIR and HOME are re-exported under it BEFORE anything runs, so run.sh's startup sweep, every mktemp and every adapter act inside the
# root and never in the caller's real temp dir or home. `inroot` (below) re-checks this in every helper that starts the harness.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-selftest.XXXXXX")" || { echo "selftest: cannot create the suite root" >&2; exit 2; }
SUITE_ROOT="$tmp"; mkdir -p "$tmp/tmp" "$tmp/home"
export TMPDIR="$tmp/tmp" HOME="$tmp/home"
trap 'rm -rf "$tmp"' EXIT
# inroot [path...]: fail the WHOLE suite (one line, exit 97) unless the exported TMPDIR is under $SUITE_ROOT/tmp, the exported HOME under
# $SUITE_ROOT/home and every path given (the TMPDIR/HOME a helper overrides with) under $SUITE_ROOT. `..` is never accepted.
_under() { case "$1" in *"/.."*|*"../"*) return 1 ;; "$2"|"$2"/*) return 0 ;; esac; return 1; }
inroot() {
  local p
  _under "${TMPDIR:-}" "$SUITE_ROOT/tmp" || { echo "selftest: FATAL: TMPDIR '${TMPDIR:-}' is not under the suite root $SUITE_ROOT/tmp: refusing to start the harness outside it" >&2; exit 97; }
  _under "${HOME:-}" "$SUITE_ROOT/home" || { echo "selftest: FATAL: HOME '${HOME:-}' is not under the suite root $SUITE_ROOT/home: refusing to start the harness outside it" >&2; exit 97; }
  for p in "$@"; do
    _under "$p" "$SUITE_ROOT" && [[ "$p" != "$SUITE_ROOT" ]] || { echo "selftest: FATAL: '$p' is not under the suite root $SUITE_ROOT: refusing to start the harness outside it" >&2; exit 97; }
  done
}
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
DARWIN_ONLY_DECLARED="26l 14q2 14r 14s 14s2 14s3 14t 14u 14u2 14v 14v2 14v3 14v4 15a 15b 15i 15n 15o 15p 15q 15r 15s 15t 15u 15v 15w 15x 15y 15z1 15z2 15z3 15z4 19q 19x2 21a 22s 24a 24b 24c 24d 24e 24f 24g 24h 24i 24j 24k"
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
#   TASK_KIND=<kind> (default seeded) is written as task.json "kind"; TASK_LANG=<lang> (default go) as "language".
#   jsonobj: passes iff the agent output file is a JSON object with found==1; its reference writes
#   {"found":1} (or $REF_OUT) to the output file instead of touching done.txt.
mktask() {
  local d="$1/$2/$3"; mkdir -p "$d/fixture" "$d/reference"
  printf '{"id":"%s","skill":"%s","split":"%s","kind":"%s","language":"%s","prompt":"%s","timeout_s":%s,"max_budget_usd":0.5,"agent_mode":"read-only"}\n' \
    "$3" "$2" "$4" "${TASK_KIND:-seeded}" "${TASK_LANG:-go}" "${6:-Create done.txt in the repo.}" "${TASK_TIMEOUT:-20}" >"$d/task.json"
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
  inroot
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
    rows.append({"task": tid, "skill": skill, "split": split, "kind": "seeded", "language": "go", "arm": arm, "host": "claude", "model": model, "rep": rep, "pass": ok,
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
l="$(line '^prod-review +claude +m1 +n/a +heldout +go +seeded +skill ')"
if [[ "$l" == *"100.0% (20/20)"* && "$l" == *"1.00 (k=2)"* ]]; then r=0; else r=1; fi
note "8a report: exact rate and pass^k with k printed (skill arm)" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +heldout +go +seeded +bare ')"
if [[ "$l" == *"20.0% (4/20)"* && "$l" == *"0.20 (k=2)"* && "$l" =~ [[:space:]]0\.80[[:space:]]+n/a$ ]]; then r=0; else r=1; fi
note "8b report: bare arm 4/20, pass^k 0.20, false_pos mean per row 0.80 (16 over 20 rows)" "$r" "$l"
# cost = ALL spend / passing rows: bare spent 4*1200 + 16*3600 = 62400 tok over 4 resolved = 15600; 4*5+16*15=260 s / 4 = 65.0
if [[ "$l" == *" 15600 "* && "$l" == *" 65.0 "* ]]; then r=0; else r=1; fi
note "8c cost per resolved = total spend over all rows / passing rows" "$r" "$l"
l="$(line '^prod-ops +claude +m1 +n/a +heldout +go +seeded +bare ')"
if [[ "$l" == *"0.00 (k=2)"* && "$l" == *"45.0% (9/20)"* ]]; then r=0; else r=1; fi
note "8d pass^k is share of tasks with ALL reps passing, not k/n" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +heldout +go +seeded +\+')"
if [[ "$l" == *"+80.0 pp"* && "$l" == *helps ]]; then r=0; else r=1; fi
note "8e verdict: clear helps (task-clustered bootstrap)" "$r" "$l"
l="$(line '^prod-spec +claude +m1 +n/a +heldout +go +seeded +-')"
if [[ "$l" == *"-90.0 pp"* && "$l" == *hurts ]]; then r=0; else r=1; fi
note "8f verdict: clear hurts" "$r" "$l"
l="$(line '^prod-ops +claude +m1 +n/a +heldout +go +seeded +[-+]')"
if [[ "$l" == *"+5.0 pp"* && "$l" == *"no evidence" ]]; then r=0; else r=1; fi
note "8g verdict: no evidence" "$r" "$l"
l="$(line '^prod-review +claude +m1 +n/a +dev +go +seeded +skill ')"
if [[ "$l" == *"0.0% (0/2)"* ]]; then r=0; else r=1; fi
note "8h dev and heldout are separate rows (never pooled)" "$r" "$l"
l="$(line '^prod-review +claude +m2 +n/a +heldout +go +seeded +skill ')"; l2="$(line '^prod-review +claude +m2 +n/a +heldout +go +seeded +[-+]')"
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
            rows.append({"task": "t%d" % t, "skill": "prod-ops", "split": "dev", "kind": "seeded", "language": "go", "arm": arm, "host": "codex", "model": None, "rep": rep, "pass": True, "metrics": {}})
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
                o.write(json.dumps({"task": "t%d" % t, "skill": "prod-spec", "split": "heldout", "kind": "seeded", "language": "go", "arm": arm, "host": "claude", "model": "m", "rep": rep, "pass": x == "1", "metrics": {}}) + "\n")
PY
}
vline() { python3 -I -B "$here/report.py" "$1" 2>&1 | grep -E '^prod-spec +claude +m +n/a +heldout +go +seeded +[-+n]' || true; }
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
  '{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}' \
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
inroot "$sigtmp"
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
# EVAL_KEEP=1 no longer keeps the cell's `home` (agent-writable, credential-bearing): a case that reads what a fake CLI recorded THERE (claude.argv,
# names.txt, codex.argv) gets it from a stub python3, first on PATH in $fb: for the ONE call that removes a cell with --keep (`scrub.py rmcell
# <cell> --keep ...`) and only when TEE_HOME_TO is set, it copies <cell>/home to $TEE_HOME_TO first, then runs the real interpreter (absolute path,
# resolved here: no recursion). It is test-side only: run.sh never sees it.
REALPY0="$(command -v python3)"
printf '#!/bin/sh\ncase " $* " in *scrub.py*" rmcell "*" --keep "*) if [ -n "${TEE_HOME_TO:-}" ]; then prev=""; for a in "$@"; do if [ "$prev" = rmcell ]; then mkdir -p "$TEE_HOME_TO"; cp -R "$a/home" "$TEE_HOME_TO/" 2>/dev/null; break; fi; prev="$a"; done; fi ;; esac\nexec "%s" "$@"\n' "$REALPY0" >"$fb/python3"; chmod +x "$fb/python3"
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
if [ -f "$frec/forge" ]; then echo '{"result":"FORGED","is_error":false,"total_cost_usd":99,"usage":{"input_tokens":999999,"output_tokens":999999}}' >"\$R/.eval-claude.json"; fi
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
if [ -f "\$CODEX_HOME/auth.json" ]; then python3 -I -B -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "\$CODEX_HOME/auth.json" >"$frec/codex.authmode"; cat "\$CODEX_HOME/auth.json" >"$frec/codex.authcopy"; fi
echo \$\$ >"$frec/codex.pid"
if [ -f "$frec/hang" ]; then echo ready >"$frec/ready.fifo"; exec sleep 30; fi
if [ -f "$frec/fail" ]; then exit 7; fi
if [ -f "$frec/forge" ]; then   # the agent forges every file the OLD adapter read its answer and usage from (selftest 19x)
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"FORGED"}}' '{"type":"turn.completed","usage":{"input_tokens":999999,"output_tokens":999999}}' >"\$CODEX_HOME/.eval-codex.jsonl"
  echo FORGED >"\$CODEX_HOME/.eval-codex-last.txt"
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"FORGED2"}}' >"\$CODEX_HOME/f.tmp"; mv -f "\$CODEX_HOME/f.tmp" "\$CODEX_HOME/.eval-codex.jsonl"
fi
if [ -f "$frec/rotate" ]; then echo '{"canary":"ROTATED-CANARY"}' >"\$CODEX_HOME/auth.json"; fi
if [ -f "$frec/changereal" ]; then echo '{"canary":"OTHER-PROCESS-CANARY"}' >"$realcodex/auth.json"; fi
if [ -f "$frec/changesame" ]; then echo '{"canary":"ORIG-CANAXX"}' >"$realcodex/auth.json"; fi
if [ -f "$frec/codex.jsonl" ]; then cat "$frec/codex.jsonl"; else   # a fixture is the WHOLE stream, its own terminal event included
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'; fi
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
  inroot
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
# 14n BEFORE: a token rotated by the CLI inside its copy was written back to the real auth.json (atomic, 600).
# AFTER (the model controls the cell home, so nothing may be copied out of it): the same rotation leaves the real file
# byte-identical and the copy is scrubbed. This runs under EVAL_NO_SANDBOX=1, so it also proves the write-back is gone there.
sum16() { shasum -a 256 <"$1" | cut -c1-16; }
: >"$frec/rotate"; s_before="$(sum16 "$realcodex/auth.json")"
adapter codex read-only; arc=$?
s_after="$(sum16 "$realcodex/auth.json")"
if [[ $arc -eq 0 && ! -e "$AH/auth.json" && "$s_before" == "$s_after" && "$(cat "$realcodex/auth.json")" != *ROTATED-CANARY* \
   && -z "$(find "$realcodex" -name '.auth.*' | head -1)" ]]; then ok=0; else ok=1; fi
note "14n codex: a copy rotated or rewritten inside the cell is NOT written back (real auth.json sha $s_before -> $s_after), the copy is scrubbed" $ok "rc=$arc before=$s_before after=$s_after"
rm -f "$frec/rotate"; echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"
adapter codex read-only CODEX_API_KEY=apikey-canary; arc=$?
if [[ $arc -eq 0 && "$(cat "$frec/codex.hadauth")" == no && "$(grep -c '^CODEX_API_KEY=apikey-canary$' "$frec/codex.env")" == 1 ]]; then ok=0; else ok=1; fi
note "14o codex: an exported CODEX_API_KEY is preferred and no auth.json is copied" $ok "rc=$arc"
# EVAL_KEEP=1 through run.sh: the dir stays, the credential does not
keeptmp="$tmp/keeptmp"; mkdir -p "$keeptmp"; ktask="$(mktask "$corpus" prod-review t-keep dev good)"
inroot "$keeptmp"
env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$fb:$PATH" HOME="$realhome" TMPDIR="$keeptmp" EVAL_KEEP=1 EVAL_CODEX_REAL_HOME="$realcodex" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$ktask" --arm skill --host codex --rep 1 --out "$tmp/r14p.jsonl" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && "$(nrows "$tmp/r14p.jsonl")" == 1 && -n "$(find "$keeptmp" -mindepth 1 -maxdepth 1 -name 'eval-cell.*' | head -1)" \
   && -z "$(find "$keeptmp" -name auth.json | head -1)" && "$(cat "$frec/codex.hadauth")" == yes ]]; then ok=0; else ok=1; fi
note "14p EVAL_KEEP=1 keeps the cell dir but never the credential copy" $ok "rc=$rc left: $(find "$keeptmp" -name 'auth.json' | head -2 | tr '\n' ' ')"

# 14n2: the staged copy is a fresh 0600 file with the real file's bytes; the real file is untouched
echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"; chmod 600 "$realcodex/auth.json"; s_before="$(sum16 "$realcodex/auth.json")"
adapter codex read-only; arc=$?
if [[ $arc -eq 0 && "$(cat "$frec/codex.authmode")" == 0o600 ]] && cmp -s "$frec/codex.authcopy" "$realcodex/auth.json" && [[ "$(sum16 "$realcodex/auth.json")" == "$s_before" && ! -e "$AH/auth.json" ]]; then ok=0; else ok=1; fi
note "14n2 codex: the staged auth copy is mode 0600 with the real file's bytes, scrubbed after, real file untouched" $ok "rc=$arc mode=$(cat "$frec/codex.authmode" 2>&1)"
# 14n3: a real auth.json that is a symlink (or not a regular file) is REFUSED, never followed: exit 78, host never starts, no copy
symreal="$tmp/symreal"; mkdir -p "$symreal"; echo SYMLINK-TARGET-CANARY >"$tmp/symtarget"; ln -s "$tmp/symtarget" "$symreal/auth.json"
adapter codex read-only EVAL_CODEX_REAL_HOME="$symreal"; arc=$?
if [[ $arc -eq 78 && ! -e "$frec/codex.argv" && ! -e "$AH/auth.json" && ! -L "$AH/auth.json" ]] && ! grep -rq SYMLINK-TARGET-CANARY "$AH" "$tmp/adapter.out" "$tmp/adapter.err"; then ok=0; else ok=1; fi
note "14n3 codex staging: a symlinked real auth.json is refused (exit 78, nothing staged, target content never copied)" $ok "rc=$arc $(head -c 160 "$tmp/adapter.err")"
dirreal="$tmp/dirreal"; mkdir -p "$dirreal/auth.json"
adapter codex read-only EVAL_CODEX_REAL_HOME="$dirreal"; arc=$?
if [[ $arc -eq 78 && ! -e "$frec/codex.argv" && ! -e "$AH/auth.json" ]]; then ok=0; else ok=1; fi
note "14n4 codex staging: a real auth.json that is not a regular file is refused (exit 78)" $ok "rc=$arc"
# 14n5: scrub after a FAILING cli, and on SIGTERM to the adapter (the EXIT trap path; run.sh:75 is only a backstop)
: >"$frec/fail"; adapter codex read-only; arc=$?; rm -f "$frec/fail"
if [[ $arc -eq 7 && "$(cat "$frec/codex.hadauth")" == yes && ! -e "$AH/auth.json" ]] && cmp -s "$realcodex/auth.json" <(echo '{"canary":"ORIG-CANARY"}'); then ok=0; else ok=1; fi
note "14n5 codex: the copy is scrubbed after a failing CLI (exit 7 propagated), real file untouched" $ok "rc=$arc"
rm -f "$frec/ready.fifo" "$frec/codex.pid"; mkfifo "$frec/ready.fifo"; exec 7<>"$frec/ready.fifo"; : >"$frec/hang"
mkdir -p "$tmp/sigh" "$tmp/sigw" "$tmp/sigg"; echo "do the thing" >"$tmp/ap.txt"
inroot
( cd "$tmp" && exec env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 PATH="$fb:$PATH" HOME="$realhome" EVAL_GOCACHE="$tmp/sigg" EVAL_CODEX_REAL_HOME="$realcodex" \
  bash "$here/hosts/codex.sh" "$tmp/sigw" "$tmp/sigh" "$tmp/ap.txt" "$tmp/sigout.txt" "$tmp/sigusage.json" "" 0.5 read-only "" ) >"$tmp/sig.out" 2>"$tmp/sig.err" &
sigpid=$!
if read -r -t 20 -u 7 _ready; then sig_staged="$([[ -f "$tmp/sigh/auth.json" ]] && echo yes || echo no)"; else sig_staged=never-started; fi
kill -TERM "$sigpid" 2>/dev/null; wait "$sigpid"; sigrc=$?; exec 7<&-; rm -f "$frec/hang"
cxpid="$(cat "$frec/codex.pid" 2>/dev/null)"; if [[ -n "$cxpid" ]] && kill -0 "$cxpid" 2>/dev/null; then sig_alive=yes; kill -TERM "$cxpid" 2>/dev/null; else sig_alive=no; fi
if [[ "$sig_staged" == yes && $sigrc -eq 143 && ! -e "$tmp/sigh/auth.json" && "$sig_alive" == no && -z "$(find "$tmp" -maxdepth 1 -name 'sbx.*' | head -1)" ]]; then ok=0; else ok=1; fi
note "14n6 codex: SIGTERM to the adapter mid-run kills the CLI and scrubs the staged copy (rc 143, adapter dir removed)" $ok "staged-during-run=$sig_staged rc=$sigrc cli-alive=$sig_alive left: $(ls "$tmp/sigh" 2>&1 | tr '\n' ' ')"
# 19x (portable): the answer and the usage come from the stream the ADAPTER captured, never from a file in the agent-writable home.
# BEFORE: <home>/.eval-codex.jsonl, .eval-codex-last.txt and .eval-claude.json were read back, so a rename-over forged tokens, cost and answer.
echo '{"canary":"ORIG-CANARY"}' >"$realcodex/auth.json"; : >"$frec/forge"
adapter codex read-only CODEX_API_KEY=k; arc=$?
cxo="$(cat "$tmp/aout.txt" 2>&1)"; cxu="$(cat "$tmp/ausage.json" 2>&1)"
adapter claude read-only CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_CLAUDE_NO_SANDBOX=1; brc=$?
clo="$(cat "$tmp/aout.txt" 2>&1)"; clu="$(cat "$tmp/ausage.json" 2>&1)"; rm -f "$frec/forge"
if [[ $arc -eq 0 && $brc -eq 0 && "$cxo" == OK && "$cxu" == *'"tokens_in": 5'* && "$cxu" == *'"tokens_out": 1'* && "$clo" == OK && "$clu" == *'"cost_usd": 0.001'* && "$clu" != *999999* ]] \
   && [[ -s "$AH/.eval-claude.json" ]]; then ok=0; else ok=1; fi
note "19x answer and usage come from the adapter-captured stdout: forged <home>/.eval-codex.jsonl|.eval-codex-last.txt|.eval-claude.json change neither tokens, cost nor the graded answer" $ok "codex out=$cxo usage=$cxu | claude out=$clo usage=$clu"
# W3: a workspace-write task's grader would run unconfined on agent-written files: refused (row error grader-unconfined), grader never runs
wwcorp="$tmp/wwcorp"; wwt="$(mktask "$wwcorp" prod-review t-wwg dev always0)"; printf '#!/usr/bin/env bash\ntouch "%s"\necho "{\\"found\\":1}"; exit 0\n' "$tmp/grader-ran" >"$wwt/grade.sh"
python3 -I -B - "$wwt/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agent_mode"] = "workspace-write"; json.dump(t, open(sys.argv[1], "w"))
PY
rm -f "$tmp/grader-ran"
inroot
bash "$here/run.sh" --task "$wwt" --arm bare --host stub --rep 1 --out "$tmp/rww.jsonl" >/dev/null 2>"$tmp/rww.err"; rc=$?
rort="$(mktask "$wwcorp" prod-review t-rog dev always0)"; printf '#!/usr/bin/env bash\ntouch "%s"\necho "{\\"found\\":1}"; exit 0\n' "$tmp/grader-ran-ro" >"$rort/grade.sh"; rm -f "$tmp/grader-ran-ro"
inroot
bash "$here/run.sh" --task "$rort" --arm bare --host stub --rep 1 --out "$tmp/rro.jsonl" >/dev/null 2>&1; rc2=$?
if [[ $rc -eq 0 && "$(rowval "$tmp/rww.jsonl" error)" == grader-unconfined && "$(rowval "$tmp/rww.jsonl" pass)" == false && ! -e "$tmp/grader-ran" && "$(cat "$tmp/rww.err")" == *grader-unconfined* \
   && $rc2 -eq 0 && "$(rowval "$tmp/rro.jsonl" error)" != grader-unconfined && -e "$tmp/grader-ran-ro" ]]; then ok=0; else ok=1; fi
note "19y run.sh refuses to run the grader of a workspace-write task (error:grader-unconfined, pass:false, grader never ran); a read-only task is graded as before" $ok "rc=$rc row: $(cut -c1-220 "$tmp/rww.jsonl" 2>&1) ran=$([[ -e "$tmp/grader-ran" ]] && echo yes || echo no)"

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
  inroot "$KT"
  env -u CODEX_API_KEY TEE_HOME_TO="$KT/homecopy" ${nosb_default[@]+"${nosb_default[@]}"} PATH="$fb:$PATH" HOME="$realhome" TMPDIR="$KT" EVAL_KEEP=1 CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_SKILLS_ROOT="$skills" "$@" \
    bash "$here/run.sh" --task "$task" --arm bare --host claude --rep 1 --out "$res" >/dev/null 2>"$tmp/runclaude.err"
}
kn=0
# ---- 15p-15v: user data is DEFAULT-DENY (fake claude, REAL sandbox-exec) ----
# 15p-15s run against a FAKE tree: the adapter's selftest-only --deny-roots (adapter arg DENYROOTS=) points the denied roots at $FT instead of the
# user's real /Users, so the canaries are ours. The probe host records what it can and cannot do.
FT="$tmp/ft"; DR="$tmp/aaa-decoy:$FT"; mkdir -p "$tmp/aaa-decoy"   # the decoy root sorts FIRST: a rule honouring only its first filter would miss $FT
FHOME="$FT/u/me"; FREPO="$FT/dev/repo"; FREPO2="$FT/dev2/repo-copy"; FCELLS="$FT/cells"; SK="$tmp/sk"
fbs="$tmp/fakebin-sb"; REAL_USER_HOME="$FT/u"   # stand-in for the caller's home inside the fake tree (HOME itself is the suite's scratch home)
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
w outsideroots "$tmp/outside/canary"; r realrepo "$corpusfile"   # outside the (test) denied roots: only the baseline / the adapter's --deny-read stop these
if [ "\$TMPDIR" = "\$R/tmp" ]; then p tmpdir_env ok; else p tmpdir_env "wrong:\$TMPDIR"; fi
a() { n="\$1"; shift; if "\$@" >/dev/null 2>&1; then p "\$n" written; else p "\$n" denied; fi; }
if [ -f "$frec/forge-cl" ]; then
  echo '{"result":"FORGED","is_error":false,"total_cost_usd":99,"usage":{"input_tokens":999999,"output_tokens":999999}}' >"\$R/f.tmp"; mv -f "\$R/f.tmp" "\$R/.eval-claude.json"
  if [ -n "\$prof" ]; then d="\$(dirname "\$prof")"; a sbxforge1 sh -c 'echo FORGED >"\$1"' _ "\$d/result.json"; a sbxforge2 sh -c 'echo FORGED >"\$1/x"' _ "\$d"; fi
fi
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
# 15z1-15z4: claude, test roots that do NOT cover the repo (the adapters' own deny rules are what stop it)
if darwin_only 15z1; then
# M1: a write outside every denied root: only the baseline `(deny file-write*)` stops it
rm -f "$tmp/outside/canary"
adapter claude read-only "$TOK" ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$fbs:$fb:$PATH" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask"; arc=$?; Z1="$AH"
if [[ $arc -eq 0 && ! -e "$tmp/outside/canary" ]] && pvg "$Z1" outsideroots=denied && pvg "$Z1" home=written; then ok=0; else ok=1; fi
note "15z1 a write outside every denied root (a user-writable dir the roots do not cover) is denied by the baseline deny file-write*; the cell's own dirs stay writable" $ok "rc=$arc probe: $(pvs "$Z1")"
fi
if darwin_only 15z2; then
# M2: the repo is outside the (test) denied roots: the adapter's own --deny-read <repo> is what stops the read
if [[ -n "${Z1:-}" ]] && pvg "$Z1" realrepo=denied && pvg "$Z1" workfile=read; then ok=0; else ok=1; fi
note "15z2 claude: the repo is outside the denied roots yet unreadable (the adapter's --deny-read repo), the workdir stays readable" $ok "probe: $(pvs "${Z1:-$tmp}")"
fi
if darwin_only 15z3; then
# M3: --protect <task dir> makes the generator refuse a re-allow that would cover it (here: the task dir contains the cell)
adapter claude read-only "$TOK" ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$fbs:$fb:$PATH" DENYROOTS="$DR" EVAL_TASK_DIR="$FCELLS"; arc=$?
if [[ $arc -eq 79 && ! -e "$AH/probe.out" ]] && grep -q 'refus' "$tmp/adapter.err"; then ok=0; else ok=1; fi
note "15z3 claude: a task dir that CONTAINS the cell's dirs is refused by the profile generator (--protect on the task dir), host never starts (exit 79)" $ok "rc=$arc $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 15z4; then
# W2: TMPDIR is exported into the sandboxed process and is the cell tmp. (/bin/bash 3.2 here-docs ignore TMPDIR and write /tmp, which the
# profile denies: known noise, README.) Not fixable by an env var, so only the export is asserted.
if [[ -n "${Z1:-}" ]] && pvg "$Z1" tmpdir_env=ok && pvg "$Z1" tmp=written; then ok=0; else ok=1; fi
note "15z4 TMPDIR in the sandboxed process is the per-cell tmp and writable" $ok "probe: $(pvs "${Z1:-$tmp}")"
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
runclaude "$good" "$tmp/r15a.jsonl" EVAL_SKIP_GRADER=1; ro_arg="$(argafter "$(find "$KT" -name claude.argv | head -1)" --permission-mode)"
runclaude "$wtask" "$tmp/r15b.jsonl" EVAL_SKIP_GRADER=1; ww_arg="$(argafter "$(find "$KT" -name claude.argv | head -1)" --permission-mode)"
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
  inroot "$KC"
  env TEE_HOME_TO="$KC/homecopy" HOME="$realhome" TMPDIR="$KC" EVAL_KEEP=1 CODEX_API_KEY=k EVAL_CODEX_REAL_HOME="$realcodex" EVAL_SKILLS_ROOT="$skills" PATH="$fb:$PATH" "$@" \
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
w outsideroots "$tmp/outside/canary"; r realrepo "$corpusfile"   # outside the (test) denied roots: only the baseline / the adapter's --deny-read stop these
if [ "\$TMPDIR" = "\$R/tmp" ]; then p tmpdir_env ok; else p tmpdir_env "wrong:\$TMPDIR"; fi
p seenauth "\$(head -c 20 "\$R/auth.json" 2>/dev/null)"   # what THIS cell's staged credential holds at start (fake content only)
a() { n="\$1"; shift; if "\$@" >/dev/null 2>&1; then p "\$n" written; else p "\$n" denied; fi; }
if [ -f "$frec/rotate-cx" ]; then echo '{"canary":"ROTATED-CX"}' >"\$R/auth.json"; fi
if [ -f "$frec/write-auth-cx" ]; then echo '{"tokens":"ATTACKER-CHOSEN"}' >"\$R/auth.json"; fi   # attack (a)
if [ -f "$frec/link-auth-cx" ]; then rm -f "\$R/auth.json"; ln -s "$FHOME/.ssh/id" "\$R/auth.json"; fi   # attack (b)
if [ -f "$frec/ro-probe-cx" ]; then   # every way to change the staged file's content or its directory entry
  echo X >"\$R/x-ro"; r ro_read "\$R/auth.json"
  a ro_mvover mv -f "\$R/x-ro" "\$R/auth.json"; a ro_lnsf ln -sf "\$R/x-ro" "\$R/auth.json"
  a ro_redirect sh -c 'echo EVIL >"\$1"' _ "\$R/auth.json"; a ro_append sh -c 'echo EVIL >>"\$1"' _ "\$R/auth.json"; a ro_trunc sh -c ': >"\$1"' _ "\$R/auth.json"
  a ro_hardlink ln "\$R/auth.json" "\$R/hl"; a ro_chmod chmod 666 "\$R/auth.json"
  a ro_mvaway mv "\$R/auth.json" "\$R/gone"; a ro_rm rm -f "\$R/auth.json"
fi
if [ -f "$frec/forge-cx" ]; then   # forge the old result files AND try the adapter's capture dir (profile dir): all must fail or be ignored
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":999999,"output_tokens":999999}}' >"\$R/f.tmp"; mv -f "\$R/f.tmp" "\$R/.eval-codex.jsonl"
  echo FORGED >"\$R/.eval-codex-last.txt"
  if [ -n "\$prof" ]; then d="\$(dirname "\$prof")"
    a sbxforge1 sh -c 'echo FORGED >"\$1"' _ "\$d/events.jsonl"; a sbxforge2 sh -c 'echo FORGED >"\$1/x"' _ "\$d"
    echo FORGED >"\$R/f2.tmp"; a sbxforge3 mv -f "\$R/f2.tmp" "\$d/events.jsonl"
  fi
fi
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
allow_ln="$(grep '^(allow file-read\*' "$frec/sbx.copy")"   # captured, then matched (no early-exit grep on a pipe under pipefail)
if [[ $rc -eq 0 && -n "$cav" && "$(rowval "$tmp/r14t.jsonl" sandbox)" == seatbelt && "$(argafter "$cav" -s)" == danger-full-access && "$(argafter "$cav" -c)" == approval_policy=never ]] \
   && ! grep -q -- '--add-dir\|workspace-write\|dangerously' "$cav" && grep -qx -- --ignore-user-config "$cav" && grep -qx -- - "$cav" \
   && grep -qF "(subpath \"$binrp\")" <<<"$allow_ln" && ! grep -qF "(subpath \"$relrp\")" <<<"$allow_ln" \
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
# 14v BEFORE: "a token rotated by the sandboxed process is written back (600) and the copy scrubbed" -- the agent chose what was
# written into the user's real login. AFTER: whatever the sandboxed process leaves in its copy, the real auth.json is byte-identical
# afterwards and the copy is scrubbed. Also: TMPDIR is exported into the sandboxed process (the cell tmp).
s_before="$(sum16 "$CXR/auth.json")"; : >"$frec/rotate-cx"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
rm -f "$frec/rotate-cx"; s_after="$(sum16 "$CXR/auth.json")"
if [[ $arc -eq 0 && ! -e "$AH/auth.json" && "$s_before" == "$s_after" && "$(cat "$CXR/auth.json")" != *ROTATED-CX* && -z "$(find "$CXR" -name '.auth.*' | head -1)" ]] && pvg "$AH" tmpdir_env=ok; then ok=0; else ok=1; fi
note "14v codex under the profile: a copy rotated by the sandboxed process is NOT written back (real sha $s_before -> $s_after), the copy is scrubbed, TMPDIR is the cell tmp" $ok "rc=$arc $(pvs "$AH" | head -c 200) $(head -c 200 "$tmp/adapter.err")"
fi
if darwin_only 14v2; then
# 14v2 attack (a): the agent writes attacker-chosen JSON into $HOME/auth.json
: >"$frec/write-auth-cx"; s_before="$(sum16 "$CXR/auth.json")"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
rm -f "$frec/write-auth-cx"; s_after="$(sum16 "$CXR/auth.json")"
if [[ $arc -eq 0 && "$s_before" == "$s_after" && ! -e "$AH/auth.json" ]] && ! grep -q ATTACKER-CHOSEN "$CXR/auth.json"; then ok=0; else ok=1; fi
note "14v2 attack (a) echo '{\"tokens\":\"ATTACKER-CHOSEN\"}' >\$HOME/auth.json under the profile: real auth.json byte-identical ($s_before -> $s_after), copy scrubbed" $ok "rc=$arc before=$s_before after=$s_after"
fi
if darwin_only 14v4; then
# 14v4 attack (b): ln -s <the user's ssh key stand-in> $HOME/auth.json; then the NEXT cell must not see it
: >"$frec/link-auth-cx"; s_before="$(sum16 "$CXR/auth.json")"; want_seen="seenauth=$(head -c 20 "$CXR/auth.json")"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
rm -f "$frec/link-auth-cx"; s_mid="$(sum16 "$CXR/auth.json")"; link_left="$([[ -e "$AH/auth.json" || -L "$AH/auth.json" ]] && echo yes || echo no)"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc2=$?
s_after="$(sum16 "$CXR/auth.json")"
if [[ $arc -eq 0 && $arc2 -eq 0 && "$s_before" == "$s_mid" && "$s_before" == "$s_after" && "$link_left" == no && ! -L "$CXR/auth.json" ]] && grep -qxF "$want_seen" "$AH/probe.out" \
   && ! grep -rqs 'SSH-CANARY' "$AH" "$CXR/auth.json"; then ok=0; else ok=1; fi
note "14v4 attack (b) ln -s <ssh key stand-in> \$HOME/auth.json: real auth.json byte-identical after cell 1 and cell 2 ($s_before -> $s_mid -> $s_after), the link is gone, the next cell holds the fresh copy and no ssh canary" $ok "rc=$arc/$arc2 link_left=$link_left next-cell: $(grep seenauth "$AH/probe.out" 2>&1)"
fi
if darwin_only 14v3; then
# 14v3 the opt-in read-only staged copy (EVAL_CODEX_AUTH_READONLY=1): readable, and no write/replace/rename/unlink/link/chmod works on it
: >"$frec/ro-probe-cx"; s_before="$(sum16 "$CXR/auth.json")"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR" EVAL_CODEX_AUTH_READONLY=1; arc=$?
ROH="$AH"; ro_ok=1; if [[ $arc -eq 0 ]] && pvg "$ROH" ro_read=read && pvg "$ROH" ro_mvover=denied && pvg "$ROH" ro_lnsf=denied && pvg "$ROH" ro_redirect=denied && pvg "$ROH" ro_append=denied \
   && pvg "$ROH" ro_trunc=denied && pvg "$ROH" ro_hardlink=denied && pvg "$ROH" ro_chmod=denied && pvg "$ROH" ro_mvaway=denied && pvg "$ROH" ro_rm=denied \
   && grep -q '^(deny file-write\* (literal "[^"]*/auth.json"))$' "$frec/sbx.copy"; then ro_ok=0; fi
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc2=$?   # control: default (writable)
rm -f "$frec/ro-probe-cx"; s_after="$(sum16 "$CXR/auth.json")"
if [[ $ro_ok -eq 0 && $arc2 -eq 0 && "$s_before" == "$s_after" ]] && pvg "$AH" ro_redirect=written && pvg "$AH" ro_rm=written; then ok=0; else ok=1; fi
note "14v3 EVAL_CODEX_AUTH_READONLY=1: the staged auth.json stays readable but mv-over, ln -sf, > , >> , truncate, ln, chmod, mv-away and rm all fail under the profile; default (control) leaves it writable; real file untouched" $ok "rc=$arc/$arc2 ro: $(pvs "$ROH") | default: $(pvs "$AH")"
fi
# 19x2: under the profile the capture dir (stdout/stderr files of the adapter) cannot be written, and forged old result files change nothing
if darwin_only 19x2; then
: >"$frec/forge-cx"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
rm -f "$frec/forge-cx"; cxo="$(cat "$tmp/aout.txt" 2>&1)"; cxu="$(cat "$tmp/ausage.json" 2>&1)"
if [[ $arc -eq 0 && "$cxo" == OK && "$cxu" == *'"tokens_in": 5'* && "$cxu" == *'"tokens_out": 1'* ]] && pvg "$AH" sbxforge1=denied && pvg "$AH" sbxforge2=denied && pvg "$AH" sbxforge3=denied; then ok=0; else ok=1; fi
note "19x2 codex under the profile: forged <home>/.eval-codex.jsonl (mv-over) and -last.txt change nothing; writes/renames into the adapter's capture dir are denied; answer OK, tokens 5/1" $ok "rc=$arc out=$cxo usage=$cxu probe: $(pvs "$AH")"
: >"$frec/forge-cl"
adapter claude read-only "$TOK" ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$fbs:$fb:$PATH" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask"; arc=$?
rm -f "$frec/forge-cl"; clo="$(cat "$tmp/aout.txt" 2>&1)"; clu="$(cat "$tmp/ausage.json" 2>&1)"
if [[ $arc -eq 0 && "$clo" == OK && "$clu" == *'"cost_usd": 0.001'* && "$clu" != *999999* ]] && pvg "$AH" sbxforge1=denied && pvg "$AH" sbxforge2=denied; then ok=0; else ok=1; fi
note "19x2 claude under the profile: forged <home>/.eval-claude.json (mv-over) changes nothing; the capture dir is not writable; answer OK, cost 0.001" $ok "rc=$arc out=$clo usage=$clu probe: $(pvs "$AH")"
fi
if darwin_only 14s3; then
# codex M1/M2/M3: a write OUTSIDE the denied roots (baseline deny file-write*), the repo outside them (the adapter's --deny-read), the task dir PROTECTED
rm -f "$tmp/outside/canary"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$ttask" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
if [[ $arc -eq 0 && ! -e "$tmp/outside/canary" ]] && pvg "$AH" outsideroots=denied && pvg "$AH" realrepo=denied && pvg "$AH" workfile=read && pvg "$AH" home=written; then ok=0; else ok=1; fi
note "14s3 codex, test roots not covering the repo: a write outside every denied root is denied (baseline deny file-write*) and the repo's own file is unreadable (the adapter's --deny-read)" $ok "rc=$arc probe: $(pvs "$AH")"
CXSB=1 adapter codex read-only ABASE="$FCELLS" AGIT=1 HOME="$FHOME" PATH="$CXP" DENYROOTS="$DR" EVAL_TASK_DIR="$FCELLS" EVAL_CODEX_REAL_HOME="$CXR"; arc=$?
if [[ $arc -eq 79 && ! -e "$AH/probe.out" && ! -e "$AH/auth.json" ]] && grep -q 'refus' "$tmp/adapter.err"; then ok=0; else ok=1; fi
note "14s3b codex: a task dir that CONTAINS the cell's dirs is refused by the profile generator (--protect on the task dir), host never starts" $ok "rc=$arc $(head -c 200 "$tmp/adapter.err")"
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
meta_ln="$(grep '^(allow file-read-metadata' "$ad/p.sb")"   # captured, then matched
if [[ $prc -eq 0 && "$r1" == ok && "$r2" == denied && "$r3" == denied && "$r4" == denied && "$r5" == denied ]] && grep -q '^(allow file-read-metadata (literal ' "$ad/p.sb" && ! grep -q subpath <<<"$meta_ln"; then ok=0; else ok=1; fi
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
inroot
out1="$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN PATH="$fb:$PATH" HOME="$realhome" EVAL_CLAUDE_AUTH_DIR="$emptyc" bash "$here/lib/authcheck.sh" claude 2>&1)"; rc1=$?
inroot
out2="$(env -u CODEX_API_KEY HOME="$realhome" EVAL_CODEX_REAL_HOME="$tmp/emptyx" bash "$here/lib/authcheck.sh" codex 2>&1)"; rc2=$?
inroot
out3="$(env -u CODEX_API_KEY HOME="$realhome" EVAL_CODEX_REAL_HOME="$realcodex" bash "$here/lib/authcheck.sh" codex 2>&1)"; rc3=$?
inroot
out4="$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN PATH="$fb:$PATH" HOME="$realhome" EVAL_CLAUDE_AUTH_DIR="$realclaude" bash "$here/lib/authcheck.sh" claude 2>&1)"; rc4=$?
if [[ $rc1 -eq 78 && $out1 == missing && $rc2 -eq 78 && $out2 == missing && $rc3 -eq 0 && $out3 == ok && $rc4 -eq 0 && $out4 == ok ]]; then ok=0; else ok=1; fi
note "16b authcheck: missing -> exit 78, present -> ok (claude and codex)" $ok "claude-empty=$rc1/$out1 codex-empty=$rc2/$out2 codex-ok=$rc3/$out3 claude-ok=$rc4/$out4"
# live loop: preflight refuses; a host that loses auth stops the loop after the first cell (N4)
lc="$tmp/livecorp"; ld="$tmp/liveres"; mktask "$lc" prod-review t-live dev good >/dev/null
live() { inroot; env EVAL_LIVE=1 EVAL_CORPUS="$lc" EVAL_RESULTS_DIR="$ld" EVAL_SKILLS_ROOT="$skills" HOME="$realhome" "$@" bash "$here/lib/live.sh" >"$tmp/live.out" 2>"$tmp/live.err"; }
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
                o.write(json.dumps({"task": "t%d" % t, "skill": "prod-spec", "split": "heldout", "kind": "seeded", "language": "go", "arm": arm, "host": "claude",
                                    "model": "m", "rep": rep, "pass": ok, "metrics": {}}) + "\n")
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w1.jsonl" 2>&1 | grep -E '^prod-spec +claude +m +n/a +heldout +go +seeded +\+' || true)"
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
        r.update({"skill": "prod-ops", "split": "dev", "kind": "seeded", "language": "go", "arm": "skill", "host": "codex", "model": "m", "rep": 1, "pass": True, "metrics": {}})
        o.write(json.dumps(r) + "\n")
    for r in rows[:1]:
        pass
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w5.jsonl" 2>&1 | grep -E '^prod-ops +codex +m +n/a +dev +go +seeded +skill ' || true)"
if [[ "$l" == *"150 (2 no usage)"* ]]; then ok=0; else ok=1; fi
note "16h report: rows with no usage are excluded from the token mean and counted" $ok "$l"
python3 -I -B - "$tmp/w5b.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as o:
    o.write(json.dumps({"task": "a", "skill": "prod-ops", "split": "dev", "kind": "seeded", "language": "go", "arm": "skill", "host": "codex", "model": "m", "rep": 1, "pass": True, "metrics": {}}) + "\n")
PY
l="$(python3 -I -B "$here/report.py" "$tmp/w5b.jsonl" 2>&1 | grep -E '^prod-ops +codex +m +n/a +dev +go +seeded +skill ' || true)"
if [[ "$l" == *"n/a (1 no usage)"* ]]; then ok=0; else ok=1; fi
note "16i report: all rows without usage -> n/a" $ok "$l"
# sandbox modes are never pooled
python3 -I -B - "$tmp/sbx.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as o:
    for sb in ("seatbelt", "off"):
        for arm in ("skill", "bare"):
            o.write(json.dumps({"task": "a", "skill": "prod-ops", "split": "dev", "kind": "seeded", "language": "go", "arm": arm, "host": "claude", "model": "m", "sandbox": sb, "rep": 1, "pass": True, "metrics": {}}) + "\n")
PY
out="$(python3 -I -B "$here/report.py" "$tmp/sbx.jsonl" 2>&1)"
if [[ "$(echo "$out" | grep -cE '^prod-ops +claude +m +seatbelt +dev +go +seeded +skill ')" == 1 && "$(echo "$out" | grep -cE '^prod-ops +claude +m +off +dev +go +seeded +skill ')" == 1 ]]; then ok=0; else ok=1; fi
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
                    o.write(json.dumps({"task": "%s%d" % (kind[0], t), "skill": "prod-review", "split": "heldout", "kind": kind, "language": "go", "arm": arm,
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
d1="$(echo "$vl" | grep -E '^prod-review +claude +m +n/a +heldout +go +seeded ' || true)"; d2="$(echo "$vl" | grep -E '^prod-review +claude +m +n/a +heldout +go +clean ' || true)"
if [[ "$nv" == 4 && "$nk" == 4 && "$d1" == *helps && "$d2" == *hurts ]]; then r=0; else r=1; fi
note "18b no pooled verdict: exactly 4 verdict lines (2 kinds x diff row + named line), every one names its kind" "$r" "n=$nv named=$nk // $vl"
mkkinds "$tmp/k2.jsonl" 3 6; out="$(python3 -I -B "$here/report.py" "$tmp/k2.jsonl" 2>&1)"
l1="$(echo "$out" | grep -E '^recall \(seeded\)' || true)"; l2="$(echo "$out" | grep -E '^false-positive control \(clean\)' || true)"
if [[ "$l1" == *"insufficient tasks (n=3)" && "$l2" != *insufficient* && "$l2" == *hurts ]]; then r=0; else r=1; fi
note "18c <5 paired seeded tasks but 6 clean: 'insufficient tasks' on the seeded line ONLY" "$r" "$l1 // $l2"
l="$(echo "$out" | grep -E '^prod-review +claude +m +n/a +heldout +go +seeded +skill ' || true)"
if [[ "$l" =~ [[:space:]]0\.00[[:space:]]+2\.00$ ]]; then r=0; else r=1; fi
note "18d report: mean false_positives and found per row printed per arm and kind (seeded skill: 0.00 / 2.00)" "$r" "$l"
{ head -n 1 "$tmp/k1.jsonl"; sed 1d "$tmp/k1.jsonl" | head -n 1 | python3 -I -B -c 'import json,sys; r=json.loads(sys.stdin.read()); del r["kind"]; print(json.dumps(r))'; } >"$tmp/nokind.jsonl"
msg="$(python3 -I -B "$here/report.py" "$tmp/nokind.jsonl" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -ne 0 && "$msg" == *"nokind.jsonl:2:"* && "$msg" == *kind* ]]; then r=0; else r=1; fi
note "18e a row without kind -> non-zero exit naming file:line (no silent default)" "$r" "rc=$rc $msg"
python3 -I -B "$here/report.py" "$tmp/k1.jsonl" >"$tmp/k.a" 2>&1; python3 -I -B "$here/report.py" "$tmp/k1.jsonl" >"$tmp/k.b" 2>&1
cmp -s "$tmp/k.a" "$tmp/k.b"; r=$?
note "18f kinds report: same seed twice -> identical output" "$r" "outputs differ"
# 18g: two languages are never pooled. Python rows: 6 seeded + 6 clean tasks (skill wins seeded, loses clean);
# Rust rows: 3 seeded tasks, skill LOSES. Pooled it would be 9 seeded tasks and a mixed number.
mkkinds "$tmp/lp.jsonl" 6 6; mkkinds "$tmp/lr0.jsonl" 3 0
python3 -I -B - "$tmp/lp.jsonl" "$tmp/lr0.jsonl" "$tmp/lang.jsonl" <<'PY'
import json, sys
with open(sys.argv[3], "w") as o:
    for f, lang, flip in ((sys.argv[1], "python", False), (sys.argv[2], "rust", True)):
        for line in open(f):
            r = json.loads(line); r["language"] = lang
            if flip and r["kind"] == "seeded": r["pass"] = (r["arm"] == "bare")
            o.write(json.dumps(r) + "\n")
PY
out="$(python3 -I -B "$here/report.py" "$tmp/lang.jsonl" 2>&1)"
lp="$(echo "$out" | grep -E '^recall \(seeded\): .*/python ' || true)"; lr="$(echo "$out" | grep -E '^recall \(seeded\): .*/rust ' || true)"
nrec="$(echo "$out" | grep -cE '^recall \(seeded\)' || true)"; ncl="$(echo "$out" | grep -cE '^false-positive control \(clean\)' || true)"
if [[ "$nrec" == 2 && "$ncl" == 1 && "$lp" == *"tasks=6"*helps && "$lr" == *"tasks=3"*"insufficient tasks (n=3)" ]]; then r=0; else r=1; fi
note "18g two languages are never pooled: one recall line per language (python 6 tasks helps / rust 3 tasks insufficient), clean only for python" "$r" "n=$nrec/$ncl // $lp // $lr"
{ head -n 1 "$tmp/k1.jsonl"; sed 1d "$tmp/k1.jsonl" | head -n 1 | python3 -I -B -c 'import json,sys; r=json.loads(sys.stdin.read()); del r["language"]; print(json.dumps(r))'; } >"$tmp/nolang.jsonl"
msg="$(python3 -I -B "$here/report.py" "$tmp/nolang.jsonl" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -ne 0 && "$msg" == *"nolang.jsonl:2:"* && "$msg" == *language* ]]; then r=0; else r=1; fi
note "18h a row without language -> non-zero exit naming file:line (no silent default)" "$r" "rc=$rc $msg"

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
# 19c BEFORE: --output-schema <path> AND -o <home>/.eval-codex-last.txt (read back). AFTER: --output-schema only; no -o, no file in the cell is read back.
if [[ $arc -eq 0 && "$(argafter "$xv" --output-schema)" == "$sch" ]] && ! grep -qx -- -o "$xv" && ! grep -q 'eval-codex' "$xv"; then ok=0; else ok=1; fi
note "19c codex with a schema file: --output-schema <that path>, and NO -o / no result file in the cell" $ok "rc=$arc $(tr '\n' '|' <"$xv")"
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
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"findings\":[{\"id\":5}]}"}}' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}' >"$frec/codex.jsonl"
ADAPTER_SCHEMA="$sch" adapter codex read-only CODEX_API_KEY=k; arc=$?
# 19h BEFORE: the -o last-message file was the document, preferred over the JSONL item. AFTER: a -o file (decoy {"id":3}, written if -o were passed) is never read; the stream's item is the document.
if [[ $arc -eq 0 && "$(jdoc "$tmp/aout.txt")" == '{"findings": [{"id": 5}]}' ]]; then ok=0; else ok=1; fi
note "19h codex: the stream's last agent_message is the document; a decoy last-message file is never read" $ok "rc=$arc out: $(head -c 200 "$tmp/aout.txt")"
rm -f "$frec/codex.last"; printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"findings\":[{\"id\":4}]}"}}' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}' >"$frec/codex.jsonl"
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
cl="$(TASK_LANG=rust mktask "$tmp/lcorp" prod-review t-rust heldout good)"; r="$tmp/r19f2.jsonl"; cell "$r" "$cl" skill solve
if [[ "$(rowval "$r" language)" == rust ]]; then ok=0; else ok=1; fi
note "19p2 row language is copied from task.json (rust)" $ok "row: $(cut -c1-300 "$r" 2>&1)"
# through run.sh with the FAKE hosts: the 9th adapter argument really carries the schema
echo '{"result":"x","is_error":false,"usage":{},"structured_output":{"found":1,"findings":[]}}' >"$frec/claude.out"
# 19q needs a GRADED claude row, which exists only where a confined cell does (macOS seatbelt); elsewhere run.sh refuses
# to grade an unconfined agent's workdir (grader-unconfined) and 19q2 asserts that refusal instead.
if darwin_only 19q; then
runclaude "$jt" "$tmp/r19g.jsonl"
if [[ "$(rowval "$tmp/r19g.jsonl" output_valid)" == true && "$(rowval "$tmp/r19g.jsonl" pass)" == true && "$(argafter "$(find "$KT" -name claude.argv | head -1)" --json-schema)" == "$compact" ]]; then ok=0; else ok=1; fi
note "19q run.sh -> claude adapter: schema passed, structured document graded, row output_valid:true" $ok "row: $(cut -c1-300 "$tmp/r19g.jsonl" 2>&1)"
fi
if [[ "$PLATFORM" != Darwin ]]; then
  runclaude "$jt" "$tmp/r19g2.jsonl"; rc19q2=$?
  if [[ $rc19q2 -eq 0 && "$(nrows "$tmp/r19g2.jsonl")" == 1 && "$(rowval "$tmp/r19g2.jsonl" error)" == grader-unconfined && "$(rowval "$tmp/r19g2.jsonl" sandbox)" == off \
     && "$(rowval "$tmp/r19g2.jsonl" pass)" == false && "$(rowval "$tmp/r19g2.jsonl" exit)" == -1 && -z "$(find "$KT" -name claude.argv 2>/dev/null | head -1)" ]]; then ok=0; else ok=1; fi
  note "19q2 run.sh -> claude adapter, no confined cell (sandbox off): the row is grader-unconfined, pass:false, exit -1, the host was never invoked, run.sh exits 0" $ok "rc=$rc19q2 invoked=$(find "$KT" -name claude.argv 2>/dev/null | head -1) row: $(cut -c1-300 "$tmp/r19g2.jsonl" 2>&1)"
fi
# 19q3 (every platform): the schema reaches the claude adapter through run.sh whether or not the row can be graded
runclaude "$jt" "$tmp/r19g3.jsonl" EVAL_SKIP_GRADER=1
if [[ "$(argafter "$(find "$KT" -name claude.argv | head -1)" --json-schema)" == "$compact" && "$(rowval "$tmp/r19g3.jsonl" error)" == grader-skipped ]]; then ok=0; else ok=1; fi
note "19q3 run.sh -> claude adapter (grader skipped): the 9th argument carries the schema as --json-schema, on every platform" $ok "row: $(cut -c1-300 "$tmp/r19g3.jsonl" 2>&1)"
rm -f "$frec/claude.out"
printf '%s\n' '{"found":0,"findings":[]}' >"$frec/codex.last"   # decoy: never read now
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"found\":1,\"findings\":[]}"}}' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}' >"$frec/codex.jsonl"
inroot
env CODEX_API_KEY=k EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$fb:$PATH" HOME="$realhome" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$jt" --arm bare --host codex --rep 1 --out "$tmp/r19h.jsonl" >/dev/null 2>&1; rc=$?
rm -f "$frec/codex.last" "$frec/codex.jsonl"
if [[ $rc -eq 0 && "$(rowval "$tmp/r19h.jsonl" output_valid)" == true && "$(argafter "$frec/codex.argv" --output-schema)" == "$(cd "$scorp" && pwd)/prod-review/_lib/output.schema.json" ]]; then ok=0; else ok=1; fi
note "19r run.sh -> codex adapter: --output-schema is the skill's _lib/output.schema.json, the stream's document graded (BEFORE: the -o file)" $ok "rc=$rc row: $(cut -c1-300 "$tmp/r19h.jsonl" 2>&1)"
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
mktask "$tmp/l-nolang" prod-review t-nolang heldout good >/dev/null
python3 -I -B - "$tmp/l-nolang/prod-review/t-nolang/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); del t["language"]; json.dump(t, open(sys.argv[1], "w"))
PY
lint_case "19s2 lint RED on a task.json without language" "$tmp/l-nolang" 1 "missing key 'language'"
REF_OUT="the reference wrote prose" mktask "$tmp/l-sbad" prod-review t-sb heldout jsonobj >/dev/null; mkdir -p "$tmp/l-sbad/prod-review/_lib"; cp "$sch" "$tmp/l-sbad/prod-review/_lib/"
lint_case "19u lint RED when the reference output is not a JSON object under a schema" "$tmp/l-sbad" 1 "did not write a JSON object"
mktask "$tmp/l-sok" prod-review t-so heldout jsonobj >/dev/null; mkdir -p "$tmp/l-sok/prod-review/_lib"; cp "$sch" "$tmp/l-sok/prod-review/_lib/"
lint_case "19v lint GREEN: schema present, reference writes a JSON object, kind set" "$tmp/l-sok" 0 "lint: ok"

# ---- 21: second security review: the credential copy cannot be left behind, the grader never reads an agent-writable workdir ------
# Everything below uses a FAKE codex (a dir of ours first on PATH), a FAKE caller home and a FAKE credential. Nothing touches a real
# ~/.codex, ~/.claude* or ~/.ssh. The fake's behaviour is the content of $fx/bin/mode, read from its own install dir (the sandboxed
# environment is sealed, and a sandboxed fake may read only its own install root).
SC="$tmp/s21"; mkdir -p "$SC/stubpy" "$SC/ftdeny"; fx="$SC/fx"; mkdir -p "$fx/bin"
S21CRED='{"canary":"S21-CRED-CANARY-0451"}'
cat >"$fx/bin/codex" <<'FAKE'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")" && pwd)"; mode="$(cat "$D/mode" 2>/dev/null)"; cat >/dev/null
echo x >>"$D/invoked" 2>/dev/null
res=""
lnk() { if ln "$1" "$2" 2>/dev/null; then res="$res ln=ok"; else res="$res ln=denied"; fi; }
case "$mode" in
  perms500|perms000|uchg)
    lnk "$CODEX_HOME/auth.json" "$TMPDIR/stash.json"; lnk "$CODEX_HOME/auth.json" "$GOCACHE/stash2.json"
    cp "$CODEX_HOME/auth.json" "$TMPDIR/copy.json" 2>/dev/null && res="$res cp=ok"
    if [ "$mode" = uchg ]; then chflags uchg "$CODEX_HOME/auth.json" "$TMPDIR/stash.json" 2>/dev/null && res="$res uchg=ok"; fi
    chmod 000 "$TMPDIR" "$GOCACHE" 2>/dev/null && res="$res lockdirs=ok"
    if [ "$mode" = perms000 ]; then chmod 000 "$CODEX_HOME" && res="$res home=000"; else chmod 500 "$CODEX_HOME" && res="$res home=500"; fi ;;
  plant-git) read -r c <"$D/canary-path"; printf '[core]\n\tfsmonitor = %s\n' "sh -c 'touch $c'" >>"$PWD/.git/config" ;;
  orphan:*) rm -f "$D/orphan.pid"   # the escape (setsid) must be COMPLETE before this fake exits, else the adapter's group kill can win the race against the interpreter start and no process ever escapes
    python3 -c "import os,time;os.setsid();open('$D/orphan.pid','w').write(str(os.getpid()));time.sleep(25)  # ${mode#orphan:}" &
    for _ in $(seq 200); do [ -s "$D/orphan.pid" ] && break; sleep 0.05; done ;;
esac
if [ "$mode" = trailing ]; then
  echo '{"type":"item.completed","item":{"type":"agent_message","text":"REAL"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
  echo '{"type":"item.completed","item":{"type":"agent_message","text":"FORGED"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":999999,"output_tokens":999999}}'
  exit 0
fi
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK'"$res"'"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
FAKE
chmod +x "$fx/bin/codex"
# the removal seam of the harness is `python3 .../lib/scrub.py rmcell` (run.sh calls the interpreter by NAME, so a stub python3 first on PATH is the seam):
# the stub execs the real interpreter (absolute path resolved HERE, before PATH changes: no recursion) for everything but that one argv
REALPY="$(command -v python3)"
printf '#!/bin/sh\ncase " $* " in *scrub.py*" rmcell "*) echo "survivor: injected" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$REALPY" >"$SC/stubpy/python3"; chmod +x "$SC/stubpy/python3"
setfx() { echo "$1" >"$fx/bin/mode"; rm -f "$fx/bin/invoked"; echo "${GCAN:-$SC/canary-plant}" >"$fx/bin/canary-path"; }
echo "$S21CRED" >"$realcodex/auth.json"; chmod 600 "$realcodex/auth.json"
s21find() { grep -rl -D skip S21-CRED-CANARY-0451 "$@" 2>/dev/null | sort | tr '\n' ' '; }   # files under the given trees that hold the credential

# 21a (REAL sandbox-exec; the fake codex is confined by the same profile as a live one): the agent hard-links the staged credential
# into its tmp and gocache, copies it, locks the dirs (chmod 000) and the home (500 / 000), and sets uchg. BEFORE: `rm -f` of the copy failed
# silently and the 0600 credential stayed on disk. AFTER: the adapter resets permissions from outside, the held descriptor wipes the
# staged inode (so every hard link is empty) and the name is gone; the agent's own COPY is another inode (the cell removal's job: 21b).
if darwin_only 21a; then
  for m in perms500 perms000 uchg; do
    setfx "$m"; CXSB=1 adapter codex read-only DENYROOTS="$SC/ftdeny" PATH="$fx/bin:$fb:$PATH"; arc=$?
    python3 -I -B "$here/lib/scrub.py" reset "$AH"; python3 -I -B "$here/lib/scrub.py" reset "$AG"
    left="$(s21find "$AH" "$AG" "$tmp/adapter.out" "$tmp/adapter.err")"; said="$(cat "$tmp/aout.txt" 2>/dev/null)"
    if [[ $arc -eq 0 && ! -e "$AH/auth.json" && "$said" == *ln=ok* && "$said" == *lockdirs=ok* && -e "$AH/tmp/stash.json" && ! -s "$AH/tmp/stash.json" \
       && -e "$AG/stash2.json" && ! -s "$AG/stash2.json" && "$left" == "$AH/tmp/copy.json " ]]; then ok=0; else ok=1; fi
    note "21a/$m sandboxed codex: chmod/uchg/hard-link attack on the staged credential: name gone, every hard link wiped through the held fd (rc $arc)" $ok "rc=$arc said=[$said] left=[$left] stash=$(wc -c <"$AH/tmp/stash.json" 2>&1)"
  done
fi

# 21b run.sh level, portable (EVAL_NO_SANDBOX + EVAL_SKIP_GRADER: the host runs, the cell is removed): the whole cell is GONE after the run
kxn=0
runfx() { # runfx <mode> [env...] -> $KX (TMPDIR of the run), row in $KX.jsonl, rc in $KXRC
  KX="$tmp/kx$((++kxn))"; mkdir -p "$KX"; setfx "$1"; shift
  inroot "$KX"
  env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$fx/bin:$fb:$PATH" HOME="$realhome" TMPDIR="$KX" EVAL_CODEX_REAL_HOME="$realcodex" \
    EVAL_SKILLS_ROOT="$skills" "$@" bash "$here/run.sh" --task "$good" --arm bare --host codex --rep 1 --out "$KX.jsonl" >"$KX.out" 2>"$KX.err"
  KXRC=$?
}
for m in perms500 perms000 uchg; do
  if [[ $m == uchg ]] && ! command -v chflags >/dev/null 2>&1; then continue; fi
  runfx "$m"; python3 -I -B "$here/lib/scrub.py" reset "$KX"
  left="$(find "$KX" -mindepth 1 | head -3 | tr '\n' ' ')"
  if [[ $KXRC -eq 0 && -z "$left" && -z "$(s21find "$KX")" && "$(rowval "$KX.jsonl" error)" != scrub-failed* && "$(nrows "$KX.jsonl")" == 1 ]]; then ok=0; else ok=1; fi
  note "21b/$m run.sh: after a chmod/uchg/hard-link attack the cell is removed (nothing left under the temp root, no credential byte anywhere)" $ok "rc=$KXRC left=[$left] row-error=$(rowval "$KX.jsonl" error)"
done

# 21c removal FAILS (a stub python3 first on PATH, test-only: `scrub.py rmcell` exits 1 `survivor: injected`, everything else runs the real interpreter): the row says scrub-failed with the path, exit 4, a loud line, and the staged
# inode plus every hard link to it are already EMPTY (the fd wipe does not depend on removal). The agent's own copy (copy.json) is the
# one place the bytes survive, which is why the removal verification and the exit status exist.
runfx perms500 PATH="$SC/stubpy:$fx/bin:$fb:$PATH"; python3 -I -B "$here/lib/scrub.py" reset "$KX"
cell="$(find "$KX" -maxdepth 1 -name 'eval-cell.*' | head -1)"
left="$(s21find "$KX")"
if [[ $KXRC -eq 4 && "$(rowval "$KX.jsonl" error)" == scrub-failed:* && "$(cat "$KX.err")" == *"SCRUB FAILED"* && -n "$cell" \
   && ! -s "$cell/home/auth.json" && -e "$cell/celltmp/stash.json" && ! -s "$cell/celltmp/stash.json" \
   && -e "$cell/gocache/stash2.json" && ! -s "$cell/gocache/stash2.json" && "$left" == "$cell/celltmp/copy.json " ]]; then ok=0; else ok=1; fi
note "21c removal failure: row error scrub-failed:<path>, exit 4, SCRUB FAILED on stderr, hard-linked credential content already wiped" $ok "rc=$KXRC row-error=$(rowval "$KX.jsonl" error) cell=[$cell] left=[$left]"
runfx perms500 PATH="$SC/stubpy:$fx/bin:$fb:$PATH" EVAL_KEEP=1; python3 -I -B "$here/lib/scrub.py" reset "$KX"
# (EVAL_KEEP keeps the dirs but never the credential name)
if [[ $KXRC -eq 0 && -z "$(find "$KX" -name auth.json | head -1)" || $KXRC -eq 4 ]]; then ok=0; else ok=1; fi
note "21c2 EVAL_KEEP=1 never keeps the credential copy (name removed, or exit 4 when removal failed)" $ok "rc=$KXRC"

# 21d the Codex stream: exactly one terminal event, nothing after it, one final answer candidate
w() { printf '%s\n' "$@" >"$SC/st.jsonl"; }
A='{"type":"item.completed","item":{"type":"agent_message","text":"ANSWER"}}'; B='{"type":"item.completed","item":{"type":"agent_message","text":"SECOND"}}'
T='{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'; F='{"type":"turn.completed","usage":{"input_tokens":999999,"output_tokens":999999}}'
C='{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}'; R='{"type":"item.completed","item":{"type":"reasoning","text":"hm"}}'
pc() { python3 -I -B "$here/lib/parse_codex.py" "$SC/st.jsonl" "$SC/st.out" "$SC/st.usage" 2>/dev/null; }
w "$A" "$T"; pc >/dev/null; r1=$?; o1="$(cat "$SC/st.out")"
w "$A" "$C" "$B" "$T"; pc >/dev/null; r2=$?; o2="$(cat "$SC/st.out")"
w "$R" "$A" "$R" "$T"; pc >/dev/null; r3=$?
w "$A" "$T" "$B" "$F"; tok="$(pc)"; r4=$?; u4="$(cat "$SC/st.usage")"; o4="$(cat "$SC/st.out")"
w "$A" "$T" "$F"; pc >/dev/null; r5=$?
w "$A" "$B" "$T"; tok6="$(pc)"; r6=$?
w "$A" "$T" ""; pc >/dev/null; r7=$?
if [[ $r1 -eq 0 && "$o1" == ANSWER && $r2 -eq 0 && "$o2" == SECOND && $r3 -eq 0 && $r4 -eq 3 && "$tok" == stream-trailing-data && "$u4" == *'"tokens_in": null'* && -z "$o4" \
   && $r5 -eq 3 && $r6 -eq 3 && "$tok6" == stream-trailing-data && $r7 -eq 0 ]]; then ok=0; else ok=1; fi
note "21d parse_codex: events after turn.completed (a forged answer, a second terminal/usage) and two final answers after the last tool call are rejected (exit 3, stream-trailing-data); a tool call between answers, reasoning and a trailing blank line are fine" $ok "r=$r1,$r2,$r3,$r4,$r5,$r6,$r7 tok=[$tok] usage=$u4"
runfx trailing; ec="$(rowval "$KX.jsonl" error)"
if [[ $KXRC -eq 0 && "$ec" == stream-trailing-data && "$(rowval "$KX.jsonl" pass)" == false ]]; then ok=0; else ok=1; fi
note "21d2 codex adapter + run.sh: a stream with a forged event after turn.completed gives the row error stream-trailing-data, pass:false, no forged usage" $ok "rc=$KXRC row: $(cut -c1-260 "$KX.jsonl" 2>&1)"

# 21e a setsid process that holds the stdout pipe cannot keep the adapter waiting: bounded grace, error orphan-process (BEFORE: 25 s here)
omark="EVORPHAN-$$-$RANDOM"; setfx "orphan:$omark"; rm -f "$fx/bin/orphan.pid"
t0=$SECONDS; adapter codex read-only PATH="$fx/bin:$fb:$PATH"; arc=$?; el=$((SECONDS - t0))
opid="$(cat "$fx/bin/orphan.pid" 2>/dev/null)"; if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then oalive=yes; kill -TERM "$opid" 2>/dev/null; else oalive=no; fi
if [[ $arc -eq 81 && $el -le 12 && "$(cat "$tmp/adapter.err")" == *orphan-process* && "$oalive" == yes ]]; then ok=0; else ok=1; fi
note "21e codex adapter: an escaped (setsid) process holding the stdout pipe is detected after a bounded grace (rc 81, loud orphan-process line, ${el}s not 25s)" $ok "rc=$arc elapsed=${el}s alive=$oalive err: $(head -c 200 "$tmp/adapter.err")"
runfx "orphan:$omark"; oe="$(rowval "$KX.jsonl" error)"; opid="$(cat "$fx/bin/orphan.pid" 2>/dev/null)"; [[ -n "$opid" ]] && kill -TERM "$opid" 2>/dev/null
if [[ "$oe" == orphan-process ]]; then ok=0; else ok=1; fi
note "21e2 run.sh records error orphan-process for it" $ok "row-error=$oe"
sleep 0.2; if [[ -z "$(pgrep -f "$omark" 2>/dev/null)" ]]; then ok=0; else ok=1; fi
note "21e3 no fake orphan process of this selftest is left" $ok "pgrep: $(pgrep -f "$omark" 2>/dev/null | tr '\n' ' ')"

# 21f the grader only ever reads a workdir the agent could not write
# (1) git neutralised: a repo-local core.fsmonitor planted by the HARNESS-side setup (so the digest matches) must not run under the grader
GCAN="$SC/fsmonitor-ran"; rm -f "$GCAN"
gt="$(mktask "$SC/gcorp" prod-review t-gitenv dev always0)"
printf '#!/usr/bin/env bash\ncd "$1" && git status >/dev/null 2>&1\necho "{\\"found\\":1}"; exit 0\n' >"$gt/grade.sh"
printf '#!/usr/bin/env bash\ngit config core.fsmonitor %q\n' "sh -c 'touch $GCAN' #" >"$gt/fixture.setup.sh"
# control: the plant works (plain git status runs it), otherwise (1) proves nothing
ctl="$SC/ctlrepo"; mkdir -p "$ctl"; ( cd "$ctl" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q . && git config core.fsmonitor "sh -c 'touch $GCAN' #" && echo a >f && git status >/dev/null 2>&1 ); ctlran=no; [[ -e "$GCAN" ]] && ctlran=yes; rm -f "$GCAN"
inroot
bash "$here/run.sh" --task "$gt" --arm bare --host stub --rep 1 --out "$SC/r21f1.jsonl" >/dev/null 2>&1; rc=$?
if [[ "$ctlran" == yes && $rc -eq 0 && ! -e "$GCAN" && "$(rowval "$SC/r21f1.jsonl" pass)" == true ]]; then ok=0; else ok=1; fi
note "21f1 the grader's git is neutralised: a repo-local core.fsmonitor (control: it does run under plain git) never runs under run.sh's grader" $ok "control-ran=$ctlran rc=$rc canary=$([[ -e "$GCAN" ]] && echo RAN || echo absent) row: $(cut -c1-200 "$SC/r21f1.jsonl" 2>&1)"
# (2) EVAL_NO_SANDBOX codex: the workdir is writable in every mode -> grader refused BEFORE the host starts
rm -f "$GCAN"; : >"$SC/r21f2.jsonl"
setfx plant-git
inroot
env CODEX_API_KEY=k EVAL_NO_SANDBOX=1 PATH="$fx/bin:$fb:$PATH" HOME="$realhome" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$gt" --arm bare --host codex --rep 1 --out "$SC/r21f2.jsonl" >/dev/null 2>"$SC/r21f2.err"; rc=$?
if [[ $rc -eq 0 && "$(rowval "$SC/r21f2.jsonl" error)" == grader-unconfined && "$(rowval "$SC/r21f2.jsonl" pass)" == false && ! -e "$GCAN" && ! -e "$fx/bin/invoked" ]]; then ok=0; else ok=1; fi
note "21f2 codex under EVAL_NO_SANDBOX=1, read-only task: error grader-unconfined, the host is NEVER started (no model call), grader canary absent" $ok "rc=$rc invoked=$([[ -e "$fx/bin/invoked" ]] && echo yes || echo no) row: $(cut -c1-200 "$SC/r21f2.jsonl" 2>&1)"
# (3) the host DID run (explicit EVAL_SKIP_GRADER) and planted a git config: workdir-tampered, grader never runs
setfx plant-git; : >"$SC/r21f3.jsonl"
inroot
env CODEX_API_KEY=k EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$fx/bin:$fb:$PATH" HOME="$realhome" EVAL_SKILLS_ROOT="$skills" \
  bash "$here/run.sh" --task "$gt" --arm bare --host codex --rep 1 --out "$SC/r21f3.jsonl" >/dev/null 2>"$SC/r21f3.err"; rc=$?
if [[ $rc -eq 0 && "$(rowval "$SC/r21f3.jsonl" error)" == workdir-tampered && ! -e "$GCAN" && -e "$fx/bin/invoked" ]]; then ok=0; else ok=1; fi
note "21f3 a git config planted while the CLI ran: error workdir-tampered, grader never runs (canary absent)" $ok "rc=$rc row: $(cut -c1-200 "$SC/r21f3.jsonl" 2>&1)"
# (4) digest surfaces, harness-side simulation through the stub host (sandbox n/a, graded): config, hooks, attributes tamper; index/worktree edits do not
for tm in cfg hook attr; do
  case "$tm" in
    cfg) cat >"$SC/tamper.sh" <<EOF
#!/usr/bin/env bash
printf '[core]\n\tfsmonitor = %s\n' "sh -c 'touch $GCAN'" >>"\$1/.git/config"
EOF
    ;;
    hook) cat >"$SC/tamper.sh" <<EOF
#!/usr/bin/env bash
printf '#!/bin/sh\ntouch $GCAN\n' >"\$1/.git/hooks/post-checkout"; chmod +x "\$1/.git/hooks/post-checkout"
EOF
    ;;
    attr) printf '#!/usr/bin/env bash\necho "* filter=x" >"$1/.gitattributes"\n' >"$SC/tamper.sh" ;;
  esac
  rm -f "$GCAN"
  inroot
  env STUB_MODE=solve STUB_SOLVE_CMD="$SC/tamper.sh" bash "$here/run.sh" --task "$gt" --arm bare --host stub --rep 1 --out "$SC/r21g-$tm.jsonl" >/dev/null 2>&1; rc=$?
  if [[ $rc -eq 0 && "$(rowval "$SC/r21g-$tm.jsonl" error)" == workdir-tampered && "$(rowval "$SC/r21g-$tm.jsonl" pass)" == false && ! -e "$GCAN" ]]; then ok=0; else ok=1; fi
  note "21g/$tm workdir tamper ($tm) between prepare and grade: error workdir-tampered, pass:false, grader canary absent" $ok "rc=$rc row: $(cut -c1-200 "$SC/r21g-$tm.jsonl" 2>&1)"
done
printf '#!/usr/bin/env bash\ntouch "$1/done.txt"; echo edit >>"$1/README.md"; git -C "$1" status >/dev/null 2>&1\n' >"$SC/benign.sh"   # (the index is part of the digest since W4: a `git add` is no longer benign, see 26f/index)
inroot
env STUB_MODE=solve STUB_SOLVE_CMD="$SC/benign.sh" bash "$here/run.sh" --task "$good" --arm bare --host stub --rep 1 --out "$SC/r21g-ok.jsonl" >/dev/null 2>&1
if [[ "$(rowval "$SC/r21g-ok.jsonl" pass)" == true && "$(rowval "$SC/r21g-ok.jsonl" error)" == "<absent>" ]]; then ok=0; else ok=1; fi
note "21g/ok worktree edits (tracked and untracked) and a read-only git status are NOT tamper: graded, pass:true" $ok "row: $(cut -c1-200 "$SC/r21g-ok.jsonl" 2>&1)"

# 21h startup sweep: a stale cell of ours (000 home, locked dirs, a credential-shaped file) is removed; a foreign dir, a fresh cell, a kept cell and a symlink are not
SW="$tmp/sweep"; mkdir -p "$SW/target" "$SW/other-old" "$SW/eval-cell.fresh" "$SW/eval-cell.keep" "$SW/eval-cell.stale1/home/sub" "$SW/eval-cell.stale1/celltmp"
echo FOREIGN-TARGET >"$SW/target/canary"; echo FOREIGN-OLD >"$SW/other-old/f"; : >"$SW/eval-cell.keep/.eval-keep"; echo kept >"$SW/eval-cell.keep/f"
ln -s "$SW/target" "$SW/eval-cell.link"
echo "$S21CRED" >"$SW/eval-cell.stale1/home/auth.json"; chmod 600 "$SW/eval-cell.stale1/home/auth.json"; echo "$S21CRED" >"$SW/eval-cell.stale1/celltmp/stash"
chmod 000 "$SW/eval-cell.stale1/home/sub" "$SW/eval-cell.stale1/celltmp"; chmod 500 "$SW/eval-cell.stale1/home"
touch -t 202001010000 "$SW/eval-cell.stale1" "$SW/other-old" "$SW/eval-cell.keep" "$SW/target"   # the symlink target is OLD too: only the link-vs-dir check keeps it out
inroot "$SW"
env TMPDIR="$SW" bash "$here/run.sh" --task "$good" --arm bare --host stub --rep 1 --out "$SC/r21h.jsonl" >"$SC/r21h.out" 2>"$SC/r21h.err"; rc=$?
if [[ $rc -eq 0 && ! -e "$SW/eval-cell.stale1" && -f "$SW/other-old/f" && -f "$SW/eval-cell.keep/f" && -d "$SW/eval-cell.fresh" && -L "$SW/eval-cell.link" \
   && "$(cat "$SW/target/canary")" == FOREIGN-TARGET && "$(cat "$SC/r21h.err")" == *"startup sweep removed stale cell $SW/eval-cell.stale1"* \
   && -z "$(s21find "$SW")" ]]; then ok=0; else ok=1; fi
note "21h startup sweep removes a stale own cell with a 000 home (and prints it), leaves a foreign dir, a fresh cell, a .eval-keep cell and a symlink alone" $ok "rc=$rc stale=$([[ -e "$SW/eval-cell.stale1" ]] && echo STILL-THERE || echo gone) other=$([[ -f "$SW/other-old/f" ]] && echo ok || echo REMOVED) link=$([[ -L "$SW/eval-cell.link" ]] && echo ok || echo REMOVED) err: $(head -c 200 "$SC/r21h.err")"

# 21i pre-flight: the decision lives in run.sh --preflight and is taken before any host/model call
mkdir -p "$SC/pcorp"; wpt="$(mktask "$SC/pcorp" prod-review t-pfw dev good)"
python3 -I -B - "$wpt/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agent_mode"] = "workspace-write"; json.dump(t, open(sys.argv[1], "w"))
PY
pf() { inroot; env "${@:2}" bash "$here/run.sh" --task "$1" --host "${PFHOST:-codex}" --arm bare --rep 1 --preflight >/dev/null 2>&1; echo $?; }
pa="$(PFHOST=stub pf "$good" X=1)"; pb="$(PFHOST=stub pf "$wpt" X=1)"; pc_="$(pf "$good" EVAL_NO_SANDBOX=1)"; pd="$(PFHOST=claude pf "$good" EVAL_CLAUDE_NO_SANDBOX=1)"; pe="$(pf "$wpt" X=1)"
pg=5; if [[ "$PLATFORM" == Darwin ]]; then pg="$(pf "$good" X=1)"; else pg=0; fi
if [[ "$pa" == 0 && "$pb" == 5 && "$pc_" == 5 && "$pd" == 5 && "$pe" == 5 && "$pg" == 0 ]]; then ok=0; else ok=1; fi
note "21i run.sh --preflight: graded only for read-only + (seatbelt | stub); refused (exit 5) for workspace-write and for any unsandboxed host" $ok "stub-ro=$pa stub-ww=$pb codex-nosb=$pc_ claude-nosb=$pd codex-ww=$pe codex-seatbelt-ro=$pg"
# live.sh: skips such a cell BEFORE run.sh, so no host is invoked and no row is written; EVAL_SKIP_GRADER is refused there
setfx normal; mkdir -p "$SC/lcorp/prod-review"; cp -R "$wpt" "$SC/lcorp/prod-review/t-pfw"
inroot
env EVAL_LIVE=1 N=1 EVAL_HOSTS=codex EVAL_CORPUS="$SC/lcorp" EVAL_RESULTS_DIR="$SC/lres" CODEX_API_KEY=k EVAL_NO_SANDBOX=1 PATH="$fx/bin:$fb:$PATH" HOME="$realhome" \
  bash "$here/lib/live.sh" >"$SC/live.out" 2>"$SC/live.err"
inroot
env EVAL_LIVE=1 N=1 EVAL_HOSTS=codex EVAL_CORPUS="$SC/lcorp" EVAL_RESULTS_DIR="$SC/lres2" CODEX_API_KEY=k EVAL_SKIP_GRADER=1 PATH="$fx/bin:$fb:$PATH" HOME="$realhome" \
  bash "$here/lib/live.sh" >/dev/null 2>"$SC/live2.err"; lrc=$?
if [[ ! -e "$fx/bin/invoked" && "$(cat "$SC/live.err")" == *"SKIP prod-review/t-pfw on codex"* && -z "$(cat "$SC/lres"/*.jsonl 2>/dev/null)" && $lrc -eq 2 && "$(cat "$SC/live2.err")" == *EVAL_SKIP_GRADER* ]]; then ok=0; else ok=1; fi
note "21j live.sh pre-flight skips an ungradeable cell with a reason before run.sh (host invoked: 0 times, no row), and refuses EVAL_SKIP_GRADER=1" $ok "invoked=$([[ -e "$fx/bin/invoked" ]] && echo yes || echo no) live.err: $(head -c 300 "$SC/live.err")"

# ---- 22: the harness never removes or chmods by a path the agent could have replaced; the suite never leaves its root ---------
# Finding 1: an agent that did `rm -rf $HOME; ln -s <victim> $HOME` made the old path-based `rm -f $home/auth.json` delete a file
# OUTSIDE the cell. Now every removal is a directory-descriptor walk (lib/scrub.py rmcell / rmname). Finding 2: the suite exports its
# own TMPDIR/HOME at the top and every helper that starts the harness calls `inroot`. Fake CLIs only, a fake victim, a fake caller home.
SD="$tmp/s22"; mkdir -p "$SD/fxt/bin" "$SD/cells" "$SD/ftdeny"; VIC="$SD/victim"
echo '{"canary":"S22-CRED-CANARY"}' >"$realcodex/auth.json"; chmod 600 "$realcodex/auth.json"
cat >"$SD/fxt/bin/codex" <<'FAKE'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")" && pwd)"; mode="$(cat "$D/mode")"; V="$(cat "$D/victim")"; cat >/dev/null
H="${CODEX_HOME:-${CLAUDE_CONFIG_DIR:-}}"
case "$mode" in
  home) rm -rf "$H"; ln -s "$V" "$H" ;;
  gocache) rm -rf "$GOCACHE"; ln -s "$V" "$GOCACHE" ;;
  celltmp) rm -rf "$TMPDIR"; ln -s "$V" "$TMPDIR" ;;
  nested) ln -s "$V" "$H/sub"; mkdir "$GOCACHE/d"; ln -s "$V" "$GOCACHE/d/e"; ln -s "$V/auth.json" "$TMPDIR/l" ;;
  authlink) rm -f "$H/auth.json" "$H/.credentials.json"; ln -s "$V/auth.json" "$H/auth.json"; ln -s "$V/.credentials.json" "$H/.credentials.json" ;;
esac
case "$(basename "$0")" in
  codex) echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'; echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}' ;;
  *) echo '{"result":"OK","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2}}' ;;
esac
FAKE
cp "$SD/fxt/bin/codex" "$SD/fxt/bin/claude"; chmod +x "$SD/fxt/bin/codex" "$SD/fxt/bin/claude"
# a victim directory the agent will aim at: files whose bytes, modes and mtimes must survive the cell
mkvictim() {
  rm -rf "$VIC"; mkdir -p "$VIC"; echo V-AUTH-CANARY >"$VIC/auth.json"; echo V-CRED-CANARY >"$VIC/.credentials.json"; echo V-CANARY >"$VIC/canary"
  chmod 600 "$VIC/auth.json" "$VIC/.credentials.json"; chmod 640 "$VIC/canary"; touch -t 202001010000 "$VIC/auth.json" "$VIC/.credentials.json" "$VIC/canary"
}
vsig() { python3 -I -B -c 'import hashlib,os,sys
d=sys.argv[1]
print(oct(os.stat(d).st_mode))
for n in sorted(os.listdir(d)):
    p=os.path.join(d,n); st=os.lstat(p); print(n,oct(st.st_mode),int(st.st_mtime),hashlib.sha256(open(p,"rb").read()).hexdigest()[:12])' "$1"; }
t22n=0
t22() { # t22 <host> <mode> [env...] -> $T22 (the run's TMPDIR), row in $T22.jsonl, rc in $T22RC; the fake agent tampers as <mode> says, aimed at $VIC
  local h="$1" m="$2"; shift 2; T22="$tmp/t22-$((++t22n))"; mkdir -p "$T22"
  echo "$m" >"$SD/fxt/bin/mode"; echo "$VIC" >"$SD/fxt/bin/victim"
  inroot "$T22" "$realhome"
  env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 EVAL_CLAUDE_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$SD/fxt/bin:$fb:$PATH" HOME="$realhome" TMPDIR="$T22" \
    EVAL_CODEX_REAL_HOME="$realcodex" CLAUDE_CODE_OAUTH_TOKEN=CRED-CANARY-123 EVAL_SKILLS_ROOT="$skills" "$@" \
    bash "$here/run.sh" --task "$good" --arm bare --host "$h" --rep 1 --out "$T22.jsonl" >"$T22.out" 2>"$T22.err"
  T22RC=$?
}
chk22() { # chk22 <case> <host> <mode> <keep 0|1> <wanted row error, or "-" for: NOT a cell-tampered row>
  local n="$1" h="$2" m="$3" k="$4" want="$5" before after err cellroot rpass; mkvictim; before="$(vsig "$VIC")"
  if [[ $k == 1 ]]; then t22 "$h" "$m" EVAL_KEEP=1; else t22 "$h" "$m"; fi
  after="$(vsig "$VIC")"; err="$(rowval "$T22.jsonl" error)"; rpass="$(rowval "$T22.jsonl" pass)"
  cellroot="$(find "$T22" -mindepth 1 -maxdepth 1 -name 'eval-cell.*' | head -1)"
  ok=1
  if [[ "$before" == "$after" && $T22RC -eq 0 && "$(nrows "$T22.jsonl")" == 1 ]]; then
    if [[ "$want" == - ]]; then [[ "$err" != cell-tampered* ]] && ok=0; else [[ "$err" == "$want" && "$rpass" == false ]] && ok=0; fi
  fi
  if [[ $ok -eq 0 ]]; then
    if [[ $k == 1 ]]; then   # EVAL_KEEP keeps the cell: it is still there, and removing it through the routine under test leaves nothing
      if [[ -n "$cellroot" ]] && python3 -I -B "$here/lib/scrub.py" rmcell "$cellroot" >/dev/null 2>&1 && [[ ! -e "$cellroot" ]]; then ok=0; else ok=1; fi
    else [[ -z "$cellroot" ]] && ok=0 || ok=1; fi
  fi
  note "$n victim files intact (bytes, mode, mtime), row error [$want], cell root $([[ $k == 1 ]] && echo kept || echo gone)" $ok "rc=$T22RC err=[$err] pass=$rpass cell=[$cellroot] victim: $(echo "$before" | tr '\n' ' ') -> $(echo "$after" | tr '\n' ' ')"
}
# 22a a replaced `home` (the reviewer's reproduction), both hosts, with and without EVAL_KEEP
for h in codex claude; do for k in 0 1; do chk22 "22a/$h/keep$k home -> symlink to a victim dir:" "$h" home "$k" "cell-tampered: home"; done; done
# 22b the other top-level cell children; nested links are ordinary content (unlinked as names, NOT an error row)
for h in codex claude; do
  chk22 "22b/$h gocache -> symlink:" "$h" gocache 0 "cell-tampered: gocache"
  chk22 "22b/$h celltmp -> symlink:" "$h" celltmp 0 "cell-tampered: celltmp"
  chk22 "22b/$h nested links (home/sub, gocache/d/e, celltmp/l):" "$h" nested 0 -
done
# 22c the staged credential name replaced by a symlink to a victim file: the victim survives (codex: the staged name itself is tampered)
chk22 "22c/codex/keep0 auth.json -> symlink to a victim file:" codex authlink 0 "cell-tampered: home/auth.json"
chk22 "22c/codex/keep1 auth.json -> symlink to a victim file:" codex authlink 1 "cell-tampered: home/auth.json"
chk22 "22c/claude/keep0 .credentials.json -> symlink (nested link, ordinary content):" claude authlink 0 -
# EVAL_KEEP now removes `home` as any run does (S2): links nested in it are ordinary content, as in keep0 (nothing named, victims intact)
chk22 "22c/claude/keep1 auth.json and .credentials.json -> symlinks to victim files (nested links, ordinary content, EVAL_KEEP removes home like any run):" claude authlink 1 -
# 22s (REAL sandbox-exec) the same attack under the real profile: the agent really can replace `home` there; the adapter must not follow it
if darwin_only 22s; then
  mkvictim; before="$(vsig "$VIC")"; echo home >"$SD/fxt/bin/mode"; echo "$VIC" >"$SD/fxt/bin/victim"; rm -f "$SD/cells/cell-tampered"
  CXSB=1 adapter codex read-only ABASE="$SD/cells" DENYROOTS="$SD/ftdeny" PATH="$SD/fxt/bin:$fb:$PATH"; arc=$?; after="$(vsig "$VIC")"
  if [[ $arc -eq 0 && "$before" == "$after" && ! -e "$AH" && ! -L "$AH" && "$(cat "$SD/cells/cell-tampered" 2>/dev/null)" == "$(basename "$AH")" ]]; then ok=0; else ok=1; fi
  note "22s sandboxed codex replaces its home by a symlink to a victim: victim intact, the link unlinked as a name, tampering recorded for the row" $ok "rc=$arc home=$([[ -L "$AH" ]] && echo LINK || echo ok) tampered=[$(cat "$SD/cells/cell-tampered" 2>&1)] adapter: $(head -c 300 "$tmp/adapter.err") victim: $(echo "$before" | tr '\n' ' ') -> $(echo "$after" | tr '\n' ' ')"
fi
# 22d the hostile cell contents the removal must survive
cat >"$SD/mkcell.py" <<'PY'
import os, socket, stat, sys
root = sys.argv[1]
def w(p, c=b"x"):
    with open(p, "wb") as f: f.write(c)
for d in ("home", "gocache", "celltmp", "work", "sbx.1"):
    os.makedirs(os.path.join(root, d))
w(root + "/prompt.txt")
os.makedirs(root + "/home/locked/inner"); w(root + "/home/locked/inner/f"); os.chmod(root + "/home/locked", 0)               # a mode-000 directory
os.makedirs(root + "/work/ro/sub"); w(root + "/work/ro/sub/f"); os.chmod(root + "/work/ro/sub/f", 0o400); os.chmod(root + "/work/ro/sub", 0o500); os.chmod(root + "/work/ro", 0o500)   # a read-only tree
os.mkfifo(root + "/celltmp/ff")
cwd = os.open(".", os.O_RDONLY); os.chdir(root + "/celltmp"); s = socket.socket(socket.AF_UNIX); s.bind("sock"); s.close(); os.fchdir(cwd); os.close(cwd)   # a socket (relative bind: short path)
for i in range(2000): w(root + "/gocache/f%d" % i)                                                                                # 2,000 files
cwd = os.open(".", os.O_RDONLY); os.chdir(root + "/gocache")
for i in range(200): os.mkdir("d"); os.chdir("d")
w("deep"); os.fchdir(cwd); os.close(cwd)                                                                                            # a 200-deep chain
w(root + "/home/a\nb"); os.makedirs(root + "/home/dir\nname")                                                                      # names with a newline
if hasattr(os, "chflags"):                                                                                                         # user-immutable file and directory (macOS)
    w(root + "/home/uchg-file"); os.chflags(root + "/home/uchg-file", stat.UF_IMMUTABLE)
    os.makedirs(root + "/work/uchg-dir"); w(root + "/work/uchg-dir/f"); os.chflags(root + "/work/uchg-dir", stat.UF_IMMUTABLE)
PY
CELLD="$SD/hostile"; mkdir -p "$SD/hostile-parent"; CELLD="$SD/hostile-parent/eval-cell.H"
python3 -I -B "$SD/mkcell.py" "$CELLD" >"$SD/mkcell.out" 2>&1; mrc=$?
python3 -I -B "$here/lib/scrub.py" rmcell "$CELLD" >"$SD/rmcell.out" 2>"$SD/rmcell.err"; rrc=$?
if [[ $mrc -eq 0 && $rrc -eq 0 && ! -e "$CELLD" && ! -L "$CELLD" ]]; then ok=0; else ok=1; fi
note "22d rmcell removes mode-000 dirs, a read-only tree, uchg file+dir (macOS), a FIFO, a socket, 2,000 files, a 200-deep chain, newline names" $ok "mkcell=$mrc rmcell=$rrc $(head -c 200 "$SD/mkcell.out") $(head -c 200 "$SD/rmcell.err")"
python3 -I -B "$SD/mkcell.py" "$CELLD" >/dev/null 2>&1   # --keep: the named top-level names stay, everything else goes, the root stays
python3 -I -B "$here/lib/scrub.py" rmcell "$CELLD" --keep prompt.txt --keep nonexistent >/dev/null 2>&1; krc=$?
if [[ $krc -eq 0 && "$(/bin/ls -A "$CELLD" | tr '\n' ' ')" == "prompt.txt " ]]; then ok=0; else ok=1; fi
note "22d2 rmcell --keep NAME leaves exactly the kept top-level names (and the root), removes the rest" $ok "rc=$krc left=[$(/bin/ls -A "$CELLD" 2>&1 | tr '\n' ' ')]"
python3 -I -B "$here/lib/scrub.py" rmcell "$CELLD" >/dev/null 2>&1
# 22e the routine refuses a ROOT that is a symlink or is not ours: nothing is touched
mkvictim; before="$(vsig "$VIC")"; ln -s "$VIC" "$SD/rootlink"
python3 -I -B "$here/lib/scrub.py" rmcell "$SD/rootlink" >/dev/null 2>&1; r1=$?; python3 -I -B "$here/lib/scrub.py" rmname "$SD/rootlink" auth.json >/dev/null 2>&1; r2=$?
python3 -I -B "$here/lib/scrub.py" rmname "$VIC" ../x >/dev/null 2>&1; r3=$?
asother() { python3 -I -B -c 'import importlib.util,os,sys
sp=importlib.util.spec_from_file_location("scrub",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
u=os.getuid(); m.os.getuid=lambda: u+1   # as if the directory were owned by someone else
sys.exit(m.rmcell(sys.argv[2],[]) if sys.argv[3]=="cell" else m.rmname(sys.argv[2],"auth.json"))' "$here/lib/scrub.py" "$1" "$2"; }
asother "$VIC" cell >/dev/null 2>&1; r4=$?; asother "$VIC" name >/dev/null 2>&1; r5=$?
after="$(vsig "$VIC")"
if [[ $r1 -eq 2 && $r2 -eq 2 && $r3 -eq 2 && $r4 -eq 2 && $r5 -eq 2 && "$before" == "$after" && -L "$SD/rootlink" ]]; then ok=0; else ok=1; fi
note "22e rmcell/rmname refuse a symlink ROOT, a ROOT owned by another uid and a REL with '..': exit 2, nothing touched" $ok "rc=$r1/$r2/$r3/$r4/$r5 victim: $(echo "$before" | tr '\n' ' ') -> $(echo "$after" | tr '\n' ' ')"
# 22h the swap between the stat and the open (simulated: the stat of `home` lies and reports the VICTIM's own identity while the name is a
# symlink to it): O_NOFOLLOW on the open is what refuses it; without it the victim's files would be removed
cat >"$SD/race.py" <<'PY'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("scrub", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
cell, vic = sys.argv[2], sys.argv[3]
real = os.stat; vst = real(vic)
def lying(path, *a, **k):
    if path == "home" and k.get("dir_fd") is not None:
        return vst
    return real(path, *a, **k)
m.os.stat = lying
sys.exit(m.rmcell(cell, []))
PY
mkvictim; before="$(vsig "$VIC")"; mkdir -p "$SD/race/eval-cell.R"; ln -s "$VIC" "$SD/race/eval-cell.R/home"
python3 -I -B "$SD/race.py" "$here/lib/scrub.py" "$SD/race/eval-cell.R" "$VIC" >/dev/null 2>&1; rrc=$?; after="$(vsig "$VIC")"
if [[ $rrc -ne 0 && "$before" == "$after" ]]; then ok=0; else ok=1; fi
note "22h a stat that reports the victim's identity for a symlinked name does not make rmcell follow it (O_NOFOLLOW on the open): victim intact, nonzero exit" $ok "rc=$rrc victim: $(echo "$before" | tr '\n' ' ') -> $(echo "$after" | tr '\n' ' ')"
# 22g sweep guard: unit-style string checks (no sweep is ever run against a shared temp root), then the run.sh wiring
sw_ok=0; mkdir -p "$SD/gt"; ln -s /tmp "$SD/gt/lnk"
for v in "" / /tmp /tmp/ /private/tmp /var/tmp /private/var/tmp /tmp//../tmp "$SD/gt/lnk" "$SD/gt/missing"; do
  python3 -I -B "$here/lib/scrub.py" sweepok "$v" >/dev/null 2>&1 && { sw_ok=1; echo "sweepok allowed [$v]" >"$SD/g.why"; }
done
python3 -I -B "$here/lib/scrub.py" sweepok "$SD/gt" >/dev/null 2>&1 || { sw_ok=1; echo "sweepok refused our own dir" >"$SD/g.why"; }
python3 -I -B -c 'import importlib.util,os,sys
sp=importlib.util.spec_from_file_location("scrub",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
u=os.getuid(); m.os.getuid=lambda: u+1   # as if the directory were owned by someone else
sys.exit(m.sweepok(sys.argv[2]))' "$here/lib/scrub.py" "$SD/gt" >/dev/null 2>&1 && { sw_ok=1; echo "sweepok allowed a foreign-owned dir" >"$SD/g.why"; }
inroot "$SD/gt"; env TMPDIR="$SD/gt/missing" bash "$here/run.sh" --task "$good" --arm bare --host stub --rep 1 --out "$SD/g.jsonl" >/dev/null 2>"$SD/g.err"
if [[ $sw_ok -eq 0 && "$(cat "$SD/g.err")" == *"startup sweep skipped"* ]]; then ok=0; else ok=1; fi
note "22g sweep guard: '', /, /tmp, /private/tmp, /var/tmp, a link to /tmp, a missing dir and a dir owned by another uid are refused; our own dir is allowed; run.sh prints 'startup sweep skipped'" $ok "$(cat "$SD/g.why" 2>&1) err: $(head -c 200 "$SD/g.err")"
# 22f hermeticity: with TMPDIR pointed at a directory that merely stands in for the caller's (inside the root, NOT the exported one) every
# helper that starts the harness must refuse (exit 97, `inroot`), and the old probe cell in that directory survives
STAND="$SD/callertmp"; mkdir -p "$STAND/eval-cell.SELFTESTPROBE"; echo probe >"$STAND/eval-cell.SELFTESTPROBE/f"; touch -t 202001010000 "$STAND/eval-cell.SELFTESTPROBE"
f_bad=""
for hp in "cell $SD/f.jsonl $good skill noop" "adapter codex read-only" "runclaude $good $SD/f2.jsonl" "runcodex $good $SD/f3.jsonl" "runfx noop" "live EVAL_HOSTS=none" "pf $good"; do
  # shellcheck disable=SC2086
  ( export TMPDIR="$STAND"; set -- $hp; "$@" ) >/dev/null 2>"$SD/f.err"; frc=$?
  [[ $frc -eq 97 && "$(cat "$SD/f.err")" == *"is not under the suite root"* ]] || f_bad="$f_bad [${hp%% *}:rc=$frc]"
done
( export TMPDIR=/tmp; inroot ) >/dev/null 2>&1; i1=$?; ( export HOME=/nonexistent/h; inroot ) >/dev/null 2>&1; i2=$?; ( export TMPDIR="$SD/../x"; inroot ) >/dev/null 2>&1; i3=$?
( unset TMPDIR; inroot ) >/dev/null 2>&1; i4=$?; ( inroot "$SD" ) >/dev/null 2>&1; i5=$?; ( inroot /etc ) >/dev/null 2>&1; i6=$?
if [[ -z "$f_bad" && -d "$STAND/eval-cell.SELFTESTPROBE" && -f "$STAND/eval-cell.SELFTESTPROBE/f" && $i1 -eq 97 && $i2 -eq 97 && $i3 -eq 97 && $i4 -eq 97 && $i5 -eq 0 && $i6 -eq 97 ]]; then ok=0; else ok=1; fi
note "22f hermetic: every harness-starting helper refuses a TMPDIR outside the exported suite TMPDIR (rc 97) and the probe cell survives; inroot fails for TMPDIR/HOME outside the root" $ok "bad=[$f_bad] probe=$([[ -f "$STAND/eval-cell.SELFTESTPROBE/f" ]] && echo alive || echo GONE) inroot rc=$i1/$i2/$i3/$i4/$i5/$i6"

# ---- 23: the staged credential never persists in anything the harness keeps (lib/redact.py) ------------------------------------
# Fake CLIs (no network, no model) leak a canary credential the way a real agent could; every case greps the row file, the --out dir, the
# kept cell and the whole run's temp root for the canary RAW, base64, url-safe base64 and hex and expects NOTHING. EVAL_NO_SANDBOX +
# EVAL_SKIP_GRADER: the host runs, the cell is judged on what it leaves behind.
S23="$tmp/s23"; mkdir -p "$S23/bin" "$S23/rc"
CAN="$(python3 -I -B -c 'import base64,secrets
while True:   # a canary whose standard and url-safe base64 differ, so a missing variant is visible
    t = "CANARY" + secrets.token_hex(10) + "??>~"
    if base64.b64encode(t.encode()) != base64.urlsafe_b64encode(t.encode()): print(t); break')"
CAN15="fifteen-chars-0"
printf '{"tokens":{"access_token":"%s","note":"%s"},"k":"v"}\n' "$CAN" "$CAN15" >"$S23/rc/auth.json"; chmod 600 "$S23/rc/auth.json"
python3 -I -B -c 'import base64,sys
t=sys.argv[1].encode(); u=base64.urlsafe_b64encode(t).decode()
print(t.decode()); print(base64.b64encode(t).decode()); print(u); print(u.rstrip("=")); print(t.hex()); print(t.hex().upper())' "$CAN" >"$S23/pats"
cat >"$S23/bin/common.sh" <<'FAKE'
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; mode="$(cat "$D/mode")"; SEC="$(cat "$D/secret")"
H="${CODEX_HOME:-${CLAUDE_CONFIG_DIR:-}}"
b64() { printf %s "$1" | base64 | tr -d '\n'; }
hex() { python3 -I -B -c 'import binascii,sys; sys.stdout.write(binascii.hexlify(sys.argv[1].encode()).decode())' "$1"; }   # one contiguous lowercase string on every platform (xxd is absent on Debian and wraps at 60)
hexu() { hex "$1" | tr a-f A-F; }
emit() { python3 -I -B -c 'import json,sys
t = sys.stdin.read()
if sys.argv[1] == "claude": print(json.dumps({"result": t, "is_error": False, "total_cost_usd": 0.001, "usage": {"input_tokens": 1, "output_tokens": 2}}))
else:
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": t}})); print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5, "output_tokens": 1}}))' "$FAKEHOST"; }
cat >/dev/null
case "$mode" in
  errfail) printf 'e1\ntool said: token=%s\ne3\n' "$SEC" >&2; exit 1 ;;   # three lines: the row keeps the last three, cut to 200 characters
  raw) printf 'found %s here' "$SEC" | emit ;;
  b64) printf 'found %s here' "$(b64 "$SEC")" | emit ;;
  hex) printf 'found %s here' "$(hex "$SEC")" | emit ;;
  hexu) printf 'found %s here' "$(hexu "$SEC")" | emit ;;
  json) printf '{"found":1,"note":"%s"}' "$SEC" | emit ;;
  big) python3 -I -B -c 'import sys
s = sys.argv[1]; sys.stdout.write("a" * ((1 << 20) - 10) + s + "b" * 4500000)' "$SEC" | emit ;;
  clean) printf 'all good' | emit ;;
  copies)
    printf %s "$SEC" >"$H/copy"; b64 "$SEC" >"$TMPDIR/x.b64"; printf %s "$SEC" >"$GOCACHE/g"
    printf 'my notes %s\n' "$SEC" >"$PWD/notes.txt"; { head -c 64 /dev/urandom; printf %s "$(hex "$SEC")"; head -c 64 /dev/urandom; } >"$PWD/blob.bin"
    echo harmless >"$PWD/keep.txt"; printf 'all good' | emit ;;
esac
FAKE
for h in codex claude; do printf '#!/usr/bin/env bash\nFAKEHOST=%s\nsource "$(dirname "$0")/common.sh"\n' "$h" >"$S23/bin/$h"; chmod +x "$S23/bin/$h"; done
mkdir -p "$S23/wcorp"; wt23="$(mktask "$S23/wcorp" prod-review t-ww23 dev good)"
python3 -I -B - "$wt23/task.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agent_mode"] = "workspace-write"; json.dump(t, open(sys.argv[1], "w"))
PY
t23n=0
t23() { # t23 <host> <mode> <task> [env...] -> $T23 (the run's TMPDIR), row file $T23.out/rows.jsonl, rc $T23RC, stderr $T23.err
  local h="$1" m="$2" tk="$3" auth=(); shift 3; T23="$S23/run$((++t23n))"; mkdir -p "$T23" "$T23.out"
  echo "$m" >"$S23/bin/mode"; printf %s "${LEAK:-$CAN}" >"$S23/bin/secret"
  if [[ $h == claude ]]; then auth=(CLAUDE_CODE_OAUTH_TOKEN="$CAN"); elif [[ -z "${CODEX_KEY_ROUTE:-}" ]]; then auth=(-u CODEX_API_KEY); else auth=(CODEX_API_KEY="$CAN"); fi
  inroot "$T23" "$realhome"
  env ${auth[@]+"${auth[@]}"} EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="${T23PATH:-$S23/bin:$fb:$PATH}" HOME="$realhome" TMPDIR="$T23" EVAL_CODEX_REAL_HOME="$S23/rc" \
    EVAL_SKILLS_ROOT="$skills" "$@" bash "$here/run.sh" --task "$tk" --arm bare --host "$h" --rep 1 --out "$T23.out/rows.jsonl" >"$T23.stdout" 2>"$T23.err"
  T23RC=$?; R23="$T23.out/rows.jsonl"
}
canfind() { grep -rlaF -D skip -f "$S23/pats" "$@" 2>/dev/null | sort | tr '\n' ' '; }   # files holding the canary in any of the covered encodings
v23() { rowval "$R23" "$1"; }
# 23-1 a CLI that exits 1 printing the token to stderr (both hosts): the row carries credential-in-output and not the token
for h in codex claude; do
  t23 "$h" errfail "$good"; left="$(canfind "$R23" "$T23.out" "$T23")"
  if [[ $T23RC -eq 4 && "$(v23 error)" == credential-in-output && "$(v23 pass)" == false && "$(v23 error_before)" == "host exit 1:"* && -z "$left" && "$(nrows "$R23")" == 1 \
     && "$(grep -c '^CREDENTIAL IN OUTPUT -- redacted in [0-9]* place(s)$' "$T23.err")" == 1 ]]; then ok=0; else ok=1; fi
  note "23-1/$h CLI exits 1 printing the token: row error credential-in-output (exit 4, one loud line), no canary in row/out/cell/temp root" $ok "rc=$T23RC err=$(v23 error) before=$(v23 error_before) left=[$left]"
done
# 23-2 exit 0 printing the token to stdout: raw, base64, hex (both hosts)
for h in codex claude; do for m in raw b64 hex hexu; do
  t23 "$h" "$m" "$good" EVAL_KEEP=1; left="$(canfind "$R23" "$T23.out" "$T23")"
  if [[ $T23RC -eq 4 && "$(v23 error)" == credential-in-output && "$(v23 pass)" == false && -z "$left" ]] && grep -q 'found \[REDACTED\] here' "$T23"/eval-cell.*/agent-output.txt; then ok=0; else ok=1; fi
  note "23-2/$h/$m token on stdout ($m): the kept answer is redacted in place, row credential-in-output, no canary anywhere" $ok "rc=$T23RC err=$(v23 error) left=[$left]"
done; done
# 23-3 the token inside the JSON answer document: row redacted, error, not graded (no grader metrics)
for h in codex claude; do
  t23 "$h" json "$good" EVAL_KEEP=1; left="$(canfind "$R23" "$T23.out" "$T23")"
  if [[ $T23RC -eq 4 && "$(v23 error)" == credential-in-output && "$(v23 pass)" == false && "$(v23 metrics)" == "{}" && -z "$left" ]] \
     && python3 -I -B -c 'import glob,json,sys; d=json.load(open(glob.glob(sys.argv[1]+"/eval-cell.*/agent-output.txt")[0])); sys.exit(0 if d["note"]=="[REDACTED]" and d["found"]==1 else 1)' "$T23"; then ok=0; else ok=1; fi
  note "23-3/$h the token inside the JSON answer: the stored document stays valid JSON with the value redacted, row credential-in-output, not graded" $ok "rc=$T23RC err=$(v23 error) metrics=$(v23 metrics) left=[$left]"
done
# 23-4 a nested JSON string value of a staged credential FILE (codex auth.json route): that value alone is detected
LEAK="$CAN" t23 codex raw "$good"; left="$(canfind "$R23" "$T23.out" "$T23")"
if [[ $T23RC -eq 4 && "$(v23 error)" == credential-in-output && -z "$left" ]]; then ok=0; else ok=1; fi
note "23-4 codex auth.json route: the nested access_token (>= 16 chars, NOT the whole file) is found on its own" $ok "rc=$T23RC err=$(v23 error) left=[$left]"
# 23-5 a 15-char value is not a secret; a clean run stays free of [REDACTED] and of the new row fields
LEAK="$CAN15" t23 codex raw "$good" EVAL_KEEP=1
if [[ $T23RC -eq 0 && "$(v23 error)" == grader-skipped ]] && ! grep -q 'REDACTED' "$R23" "$T23"/eval-cell.*/agent-output.txt \
   && grep -q "found $CAN15 here" "$T23"/eval-cell.*/agent-output.txt; then ok=0; else ok=1; fi
note "23-5a a 15-char JSON value is NOT treated as a secret: its text stays, no redaction, no error beyond grader-skipped, exit 0" $ok "rc=$T23RC err=$(v23 error)"
for h in codex claude; do
  t23 "$h" clean "$good" EVAL_KEEP=1
  if [[ $T23RC -eq 0 && "$(v23 error)" == grader-skipped ]] && ! grep -q 'REDACTED\|error_before\|credential_paths' "$R23" && python3 -I -B -c 'import json,sys
need = set("task skill split kind language output_valid arm host model rep pass metrics tokens_in tokens_out cost_usd duration_s exit timed_out sandbox order_seed skill_sha harness_sha ts error".split())
sys.exit(0 if set(json.loads(open(sys.argv[1]).readline())) == need else 1)' "$R23"; then ok=0; else ok=1; fi
  note "23-5b/$h a clean run: the row has exactly the pre-change keys (no error_before, no credential_paths), no [REDACTED]" $ok "rc=$T23RC row=$(cut -c1-200 "$R23")"
done
# 23-6 a secret spanning the scanner's chunk boundary in a 5 MB capture (the answer file)
for h in codex claude; do
  t23 "$h" big "$good" EVAL_KEEP=1; left="$(canfind "$R23" "$T23.out" "$T23")"
  if [[ $T23RC -eq 4 && "$(v23 error)" == credential-in-output && -z "$left" && "$(wc -c <"$(ls "$T23"/eval-cell.*/agent-output.txt)")" -gt 5000000 ]]; then ok=0; else ok=1; fi
  note "23-6/$h the canary straddles the 1 MiB chunk boundary of a 5 MB capture: found and redacted" $ok "rc=$T23RC err=$(v23 error) left=[$left]"
done
# 23-7 EVAL_KEEP=1: home gocache celltmp sbx.* are removed as in any run; work is scanned and a file holding the secret is DELETED
for h in codex claude; do
  t23 "$h" copies "$wt23" EVAL_KEEP=1; left="$(canfind "$R23" "$T23.out" "$T23")"; cellk="$(find "$T23" -mindepth 1 -maxdepth 1 -name 'eval-cell.*' | head -1)"
  gone=""; for n in home gocache celltmp; do [[ -e "$cellk/$n" ]] && gone="$gone $n"; done; [[ -n "$(find "$cellk" -maxdepth 1 -name 'sbx.*')" ]] && gone="$gone sbx"
  if [[ $T23RC -eq 4 && -n "$cellk" && -z "$gone" && ! -e "$cellk/work/notes.txt" && ! -e "$cellk/work/blob.bin" && -f "$cellk/work/keep.txt" && -f "$cellk/work/README.md" && -z "$left" \
     && "$(v23 error)" == "credential-in-kept-files: 2 file(s)" && "$(v23 pass)" == false && "$(v23 credential_paths)" == "['blob.bin', 'notes.txt']" && ! -e "$cellk/.secrets" ]]; then ok=0; else ok=1; fi
  note "23-7/$h EVAL_KEEP=1: home/gocache/celltmp/sbx gone, work/notes.txt (raw) and work/blob.bin (hex in binary) deleted, other work files kept, row credential-in-kept-files with the two paths" $ok "rc=$T23RC err=$(v23 error) paths=$(v23 credential_paths) still=[$gone] left=[$left] cell=$(ls "$cellk" 2>&1 | tr '\n' ' ')"
done
# 23-8 the secrets never appear in the argv or the environment of the helper: a python3 wrapper records both for every redact.py call
mkdir -p "$S23/rec"; REALPY23="$(command -v python3)"
printf '#!/bin/sh\ncase " $* " in *redact.py*) { echo "ARGV: $*"; env; } >>"%s/calls.txt" ;; esac\nexec "%s" "$@"\n' "$S23/rec" "$REALPY23" >"$S23/rec/python3"; chmod +x "$S23/rec/python3"
: >"$S23/rec/calls.txt"
T23PATH="$S23/rec:$S23/bin:$fb:$PATH" t23 claude errfail "$good"
T23PATH="$S23/rec:$S23/bin:$fb:$PATH" CODEX_KEY_ROUTE=1 t23 codex errfail "$good"
if [[ "$(grep -c '^ARGV: .*add-stdin' "$S23/rec/calls.txt")" -ge 2 && "$(grep -c '^ARGV: .*scan-file' "$S23/rec/calls.txt")" -ge 2 && -z "$(canfind "$S23/rec/calls.txt")" ]]; then ok=0; else ok=1; fi
note "23-8 no secret in the argv or environment of any redact.py call (claude token route and codex CODEX_API_KEY route; $(grep -c '^ARGV:' "$S23/rec/calls.txt") calls recorded)" $ok "calls=$(grep -c '^ARGV:' "$S23/rec/calls.txt") leaked-in=[$(canfind "$S23/rec/calls.txt")]"
# 23-9 redact.py on its own: links are not followed, a FIFO does not hang it
RD="$S23/rd"; mkdir -p "$RD/tree/sub" "$RD/outside"; printf 'outside holds %s\n' "$CAN" >"$RD/outside/file"; ln -s "$RD/outside/file" "$RD/tree/link"; ln -s "$RD/outside" "$RD/tree/dlink"
mkfifo "$RD/tree/fifo"; printf 'inside %s\n' "$CAN" >"$RD/tree/sub/hit.txt"; echo clean >"$RD/tree/sub/ok.txt"
printf %s "$CAN" | python3 -I -B "$here/lib/redact.py" add-stdin "$RD/sec"
# (limited.py closes inherited descriptors, so the secrets descriptor is opened INSIDE the bounded command)
python3 -I -B "$here/lib/limited.py" 10 -- bash -c 'exec python3 -I -B "$1" scan-tree 3 "$2" 3<"$3"' _ "$here/lib/redact.py" "$RD/tree" "$RD/sec" >"$RD/o" 2>&1; rrc=$?
if [[ $rrc -eq 3 && ! -e "$RD/tree/sub/hit.txt" && -f "$RD/tree/sub/ok.txt" && -L "$RD/tree/link" && -L "$RD/tree/dlink" && -p "$RD/tree/fifo" \
   && "$(cat "$RD/outside/file")" == "outside holds $CAN" && "$(cat "$RD/o")" == *"deleted sub/hit.txt"* ]]; then ok=0; else ok=1; fi
note "23-9 redact.py scan-tree: a symlink to a file/dir holding the canary is neither read nor deleted, a FIFO does not hang it (rc $rrc), the file inside is deleted" $ok "rc=$rrc out=$(head -c 200 "$RD/o")"

# ---- 24: the cell cannot leave the staged credential anywhere outside itself, nor kill the guard (lib/seatbelt.py IPC_BLOCK) --------------
# `(allow default)` leaves IPC channels open that persist or act outside the cell: POSIX shm/semaphores and SysV IPC (a named
# segment outlives the cell), signals (kill -9 of the holder disables the credential wipe) and the pasteboard. Each case runs a probe
# INSIDE a real seatbelt cell (seatbelt.py's own entry point, default roots) and checks from OUTSIDE; a control run of the same probe
# outside the sandbox proves the probe is real. Every IPC object a case creates is removed by s24_clean even when the case fails.
# provenance: candidate (TTL 2027-06-01), pinning: false -- the probe tools and operation names are those of macOS 27.x.
s24="$tmp/s24"; mkdir -p "$s24/w" "$s24/home" "$s24/gc" "$s24/tmp" "$s24/real" "$s24/hold"; inroot "$s24"
s24_id="$$"; s24_shm="/evs24s$s24_id"; s24_sem="/evs24m$s24_id"; s24_key="$(printf '0x%08x' $((0x45000000 + s24_id)))"
s24_label="com.example.evaltest.s24.$s24_id"; s24_dom="com.example.evaltest.s24$s24_id"; s24_gkey="evaltest_s24_$s24_id"
s24_realhome="$(python3 -I -B -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')"; s24_cp=""; s24_pbsaved=0
s24_pyroot="$(python3 -I -B -c 'import sys;print(sys.base_prefix)')"
S24_SHM='import os, sys, mmap
import _posixshmem as P
mode, name = sys.argv[1], sys.argv[2]
try:
    if mode == "create":
        fd = P.shm_open(name, os.O_CREAT | os.O_RDWR, 0o600); os.ftruncate(fd, 64); m = mmap.mmap(fd, 64); m[:6] = b"CANARY"; print("created")
    elif mode == "read":
        fd = P.shm_open(name, os.O_RDWR, 0o600); m = mmap.mmap(fd, 64); print("READ", bytes(m[:6]).decode())
    else:
        P.shm_unlink(name); print("unlinked")
except OSError as e:
    print("DENIED" if mode == "create" else "ABSENT", e.errno)'
S24_SEM='import sys
import _multiprocessing as M
mode, name = sys.argv[1], sys.argv[2]
try:
    if mode == "create":
        M.SemLock(0, 1, 1, name, False); print("created")
    elif mode == "exists":
        try: M.SemLock(0, 1, 1, name, False); print("ABSENT")
        except FileExistsError: print("EXISTS")
    else:
        M.sem_unlink(name); print("unlinked")
except OSError as e:
    print("DENIED" if mode == "create" else "ERR", e.errno)'
S24_SYSV='import ctypes, ctypes.util, sys
L = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
c = ctypes.c_int; key = int(sys.argv[1], 0); mk = 0o1000 | 0o600; bad = ctypes.c_void_p(-1).value
L.shmat.restype = ctypes.c_void_p; L.shmat.argtypes = [c, ctypes.c_void_p, c]
p = L.shmat(L.shmget(c(key), ctypes.c_size_t(4096), c(mk)), None, 0)
buf = ctypes.create_string_buffer(b"\x01\0\0\0\0\0\0\0CANARY", 16)
class U(ctypes.Union): _fields_ = [("val", c)]
u = U(); u.val = 1234
print("shmat=%s msgsnd=%d setval=%d" % ("FAIL" if p in (None, bad) else "OK", L.msgsnd(c(L.msgget(c(key), c(mk))), buf, ctypes.c_size_t(6), c(0)), L.semctl(c(L.semget(c(key), c(1), c(mk))), c(0), c(8), u)))'
s24_prof="$s24/p.sb"
python3 -I -B "$here/lib/seatbelt.py" "$s24/w" "$s24/home" "$s24/gc" "$s24/tmp" read-only --allow-read "$s24_pyroot" >"$s24_prof" 2>"$s24/p.err"; s24_prc=$?
s24in() { (cd "$s24/w" && env -i PATH="$PATH" HOME="$s24/home" TMPDIR="$s24/tmp" /usr/bin/sandbox-exec -f "${S24_PROF:-$s24_prof}" "$@" 2>&1 9>&-); }   # run INSIDE the cell
s24_sysv_ids() { ipcs -m -s -q 2>/dev/null | awk -v k="$s24_key" '$3 == k {print $1, $2}'; }   # "<m|s|q> <id>" of OUR key only
s24_clean() {   # idempotent; removes only objects carrying this run's unique names/key/label/domain
  [[ "$PLATFORM" == Darwin ]] || return 0
  python3 -I -B -c "$S24_SHM" unlink "$s24_shm" >/dev/null 2>&1; python3 -I -B -c "$S24_SEM" unlink "$s24_sem" >/dev/null 2>&1
  local t i; while read -r t i; do [[ -n "$t" ]] && ipcrm "-$t" "$i" 2>/dev/null; done < <(s24_sysv_ids)
  if [[ -n "$s24_cp" ]]; then kill -KILL "$s24_cp" 2>/dev/null; wait "$s24_cp" 2>/dev/null; fi; s24_cp=""
  launchctl remove "$s24_label" >/dev/null 2>&1
  HOME="$s24_realhome" defaults delete "$s24_dom" >/dev/null 2>&1; HOME="$s24_realhome" defaults delete NSGlobalDomain "$s24_gkey" >/dev/null 2>&1
  rm -f "$s24_realhome/Library/Preferences/$s24_dom.plist"   # `defaults delete` leaves an empty plist; this run's throwaway name only
  if [[ $s24_pbsaved -eq 1 ]]; then pbcopy <"$s24/pb.saved"; s24_pbsaved=0; fi
}
trap 's24_clean; rm -rf "$tmp"' EXIT

if darwin_only 24a; then   # POSIX shm
  c1="$(python3 -I -B -c "$S24_SHM" create "$s24_shm" 2>&1)"; c2="$(python3 -I -B -c "$S24_SHM" read "$s24_shm" 2>&1)"; python3 -I -B -c "$S24_SHM" unlink "$s24_shm" >/dev/null 2>&1
  i1="$(s24in python3 -I -B -c "$S24_SHM" create "$s24_shm")"; o1="$(python3 -I -B -c "$S24_SHM" read "$s24_shm" 2>&1)"; python3 -I -B -c "$S24_SHM" unlink "$s24_shm" >/dev/null 2>&1
  if [[ "$c1" == created && "$c2" == "READ CANARY" && "$i1" == DENIED* && "$o1" == ABSENT* ]]; then ok=0; else ok=1; fi
  note "24a POSIX shm: in-cell shm_open(O_CREAT) is denied and the name does not exist outside (control outside: created and read back)" $ok "control=[$c1|$c2] cell=[$i1] outside=[$o1]"
fi
if darwin_only 24b; then   # POSIX named semaphore
  c1="$(python3 -I -B -c "$S24_SEM" create "$s24_sem" 2>&1)"; c2="$(python3 -I -B -c "$S24_SEM" exists "$s24_sem" 2>&1)"; python3 -I -B -c "$S24_SEM" unlink "$s24_sem" >/dev/null 2>&1
  i1="$(s24in python3 -I -B -c "$S24_SEM" create "$s24_sem")"; o1="$(python3 -I -B -c "$S24_SEM" exists "$s24_sem" 2>&1)"; python3 -I -B -c "$S24_SEM" unlink "$s24_sem" >/dev/null 2>&1
  if [[ "$c1" == created && "$c2" == EXISTS && "$i1" == DENIED* && "$o1" == ABSENT ]]; then ok=0; else ok=1; fi
  note "24b POSIX named semaphore: in-cell sem_open(O_CREAT) is denied and the name does not exist outside (control outside: created, then seen)" $ok "control=[$c1|$c2] cell=[$i1] outside=[$o1]"
fi
if darwin_only 24c; then   # SysV shm / sem / msg: the data-carrying operations (attach, send, set value) are denied; CREATION of an empty object still succeeds on this macOS
  s24_clean; c1="$(python3 -I -B -c "$S24_SYSV" "$s24_key" 2>&1)"; n1="$(s24_sysv_ids | wc -l | tr -d ' ')"; s24_clean
  i1="$(s24in python3 -I -B -c "$S24_SYSV" "$s24_key")"; s24_clean; n2="$(s24_sysv_ids | wc -l | tr -d ' ')"
  if [[ "$c1" == "shmat=OK msgsnd=0 setval=0" && "$n1" == 3 && "$i1" == "shmat=FAIL msgsnd=-1 setval=-1" && "$n2" == 0 ]]; then ok=0; else ok=1; fi
  note "24c SysV IPC: an in-cell shmat, msgsnd and semctl(SETVAL) on objects it created are all denied (control outside: all succeed; our objects are removed afterwards)" $ok "control=[$c1]/$n1 cell=[$i1]/$n2"
fi
if darwin_only 24d; then   # signals: the holder and an unrelated process outside survive; the cell can still signal its own children
  printf 'CRED-CANARY-24\n' >"$s24/real/auth.json"; rm -f "$s24/hold/copy" "$s24/hold/ctl" "$s24/hold/holder.pid"
  python3 -I -B "$here/lib/scrub.py" hold "$s24/real/auth.json" "$s24/hold/copy" "$s24/hold/ctl" "$s24/hold/holder.pid" >/dev/null 2>&1; hrc=$?
  exec 9>"$s24/hold/ctl"; hp="$(cat "$s24/hold/holder.pid" 2>/dev/null)"; sleep 300 9>&- & s24_cp=$!
  cell_sh='for p in "$@"; do for s in 0 TERM KILL; do /bin/kill -$s "$p" 2>/dev/null; echo "k$s:$p:$?"; done; done
sleep 3 & c=$!; kill -0 "$c" && echo child-kill0-ok; kill -TERM "$c" && echo child-term-ok; wait "$c"; echo "child-status:$?"
sleep 3 & kill -KILL $! && echo child-kill9-ok'
  cres="$(s24in /bin/bash -c "$cell_sh" _ "$hp" "$s24_cp")"
  kill -0 "$hp" 2>/dev/null && h_alive=1 || h_alive=0; kill -0 "$s24_cp" 2>/dev/null && c_alive=1 || c_alive=0
  denied=1; for p in "$hp" "$s24_cp"; do for s in 0 TERM KILL; do [[ "$cres" == *"k$s:$p:1"* ]] || denied=0; done; done
  if grep -q CRED-CANARY-24 "$s24/hold/copy" 2>/dev/null; then wiped=held; else wiped=gone; fi
  exec 9>&-; python3 -I -B "$here/lib/scrub.py" waitgone "$s24/hold/holder.pid" 5; if grep -q CRED-CANARY-24 "$s24/hold/copy" 2>/dev/null; then wiped2=held; else wiped2=gone; fi
  if [[ $hrc -eq 0 && -n "$hp" && $h_alive -eq 1 && $c_alive -eq 1 && $denied -eq 1 && "$cres" == *child-kill0-ok* && "$cres" == *child-term-ok* && "$cres" == *child-status:143* \
     && "$cres" == *child-kill9-ok* && "$wiped" == held && "$wiped2" == gone ]]; then ok=0; else ok=1; fi
  note "24d signals: in-cell kill -0/-TERM/-KILL of the credential holder and of an unrelated outside process all fail and both stay alive; the cell can still signal its own children; the holder then wipes on close" $ok "hold=$hrc holder-alive=$h_alive canary-alive=$c_alive denied=$denied wiped-before=$wiped after=$wiped2 cell=[$(printf %s "$cres" | tr '\n' ' ' | cut -c1-260)]"
  s24_clean
fi
if darwin_only 24e; then   # pasteboard
  pbt="$(osascript -e 'clipboard info' 2>/dev/null | sed 's/«class[^»]*»//g; s/Unicode text//g; s/public\.utf8-plain-text//g; s/string//g; s/text//g' | tr -d '{}, 0-9')"
  if [[ -n "$pbt" ]] || ! pbpaste >"$s24/pb.saved" 2>/dev/null; then printf '  SKIP  24e (the pasteboard holds non-text data that cannot be restored: [%s]; not counted)\n' "$pbt"
  else
    s24_pbsaved=1; base="evs24-base-$s24_id"; printf %s "$base" | pbcopy; c0="$(pbpaste)"
    printf %s "evs24-canary-$s24_id" | s24in pbcopy >"$s24/pb.err" 2>&1; irc=$?
    after="$(pbpaste)"; seen="$(s24in pbpaste)"; s24_clean
    if cmp -s <(pbpaste) "$s24/pb.saved"; then restored=yes; else restored=no; fi
    if [[ "$c0" == "$base" && $irc -ne 0 && "$after" == "$base" && "$seen" != *"$base"* && "$restored" == yes ]]; then ok=0; else ok=1; fi
    note "24e pasteboard: in-cell pbcopy fails and the real pasteboard still holds what it held, an in-cell pbpaste does not see it, and the test restores the user's text" $ok "irc=$irc after=[$after] cell-paste=[$(printf %s "$seen" | head -c 60)] restored=$restored"
  fi
fi
if darwin_only 24f; then   # defaults write to the REAL user domain (HOME = the real home: a hostile agent unsets the cell's)
  HOME="$s24_realhome" defaults write "$s24_dom" k v >/dev/null 2>&1; ctl_ok=$?; ctl_v="$(HOME="$s24_realhome" defaults read "$s24_dom" k 2>/dev/null)"; HOME="$s24_realhome" defaults delete "$s24_dom" >/dev/null 2>&1
  if [[ $ctl_ok -ne 0 || "$ctl_v" != v ]]; then printf '  SKIP  24f (defaults write does not work outside the sandbox here; not counted)\n'
  else
    s24in env HOME="$s24_realhome" defaults write "$s24_dom" k v >/dev/null; s24in env HOME="$s24_realhome" defaults write NSGlobalDomain "$s24_gkey" canary >/dev/null
    d1="$(HOME="$s24_realhome" defaults read "$s24_dom" k 2>/dev/null)"; d2="$(HOME="$s24_realhome" defaults read NSGlobalDomain "$s24_gkey" 2>/dev/null)"
    s24_clean
    if [[ -z "$d1" && -z "$d2" ]]; then ok=0; else ok=1; fi
    note "24f defaults write from the cell (a throwaway app domain and NSGlobalDomain, HOME = the real home): nothing lands in the real preferences (control outside: written, read, deleted)" $ok "domain=[$d1] global=[$d2]"
  fi
fi
if darwin_only 24g; then   # launchd submit
  launchctl submit -l "$s24_label" -- /usr/bin/true >/dev/null 2>&1; ctl_ok=$?; ctl_l="$(launchctl list 2>/dev/null | grep -c "$s24_label")"; launchctl remove "$s24_label" >/dev/null 2>&1
  if [[ $ctl_ok -ne 0 || "$ctl_l" -lt 1 ]]; then printf '  SKIP  24g (launchctl submit does not work outside the sandbox here; not counted)\n'
  else
    s24in launchctl submit -l "$s24_label" -- /usr/bin/true >/dev/null; irc=$?; left="$(launchctl list 2>/dev/null | grep -c "$s24_label")"; s24_clean
    if [[ $irc -ne 0 && "$left" == 0 ]]; then ok=0; else ok=1; fi
    note "24g launchd: in-cell launchctl submit is refused (rc $irc) and no such label is listed outside (control outside: submitted, listed, removed)" $ok "rc=$irc labels-left=$left"
  fi
fi
if darwin_only 24h; then   # unix socket outside the cell (already closed: case only)
  s24h="$(python3 -I -B -c '
import os, socket, subprocess, sys
os.chdir(sys.argv[1]); p = "evs24.sock"
if os.path.exists(p): os.unlink(p)
srv = socket.socket(socket.AF_UNIX); srv.bind(p); srv.listen(5); srv.setblocking(False)
cell = subprocess.run(sys.argv[2:], capture_output=True, text=True)
try: srv.accept(); leaked = "yes"
except BlockingIOError: leaked = "no"
c = socket.socket(socket.AF_UNIX); c.connect(p); ctl = "ok"
os.unlink(p); print("cell-rc=%d leaked=%s control=%s" % (cell.returncode, leaked, ctl))' "$s24/w" /usr/bin/sandbox-exec -f "$s24_prof" "$(command -v python3)" -I -B -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect("evs24.sock")' 2>&1)"
  if [[ "$s24h" == "cell-rc=1 leaked=no control=ok" ]]; then ok=0; else ok=1; fi
  note "24h unix socket outside the cell: an in-cell connect fails and nothing reaches the listener (control outside: connects)" $ok "$s24h"
fi
if darwin_only 24i; then   # xattr outside the cell (already closed: case only)
  echo x >"$s24/real/xfile"; xattr -w user.evs24 ctl "$s24/real/xfile" >/dev/null 2>&1; ctl_ok=$?; xattr -d user.evs24 "$s24/real/xfile" >/dev/null 2>&1
  s24in xattr -w user.evs24 cell "$s24/real/xfile" >/dev/null; irc=$?; left="$(xattr "$s24/real/xfile" 2>/dev/null | grep -c evs24)"
  if [[ $ctl_ok -eq 0 && $irc -ne 0 && "$left" == 0 ]]; then ok=0; else ok=1; fi
  note "24i xattr outside the cell: an in-cell xattr -w on a file outside is refused and no attribute lands (control outside: written)" $ok "control=$ctl_ok cell-rc=$irc left=$left"
fi
if darwin_only 24j; then   # the profile loads, an ordinary cell works, and an unknown operation name is REJECTED (fail closed)
  work="$(s24in /bin/bash -c 'echo wrote-ok >"$HOME/f" && cat "$HOME/f"; sleep 0.1 & wait; python3 -I -B -c "print(40+2)"; /bin/ls "$PWD" >/dev/null && echo ls-ok')"
  { cat "$s24_prof"; echo '(deny ipc-posix-shmm*)'; } >"$s24/typo.sb"; S24_PROF="$s24/typo.sb" s24in /usr/bin/true >/dev/null; typo_rc=$?
  s24_pre=1; for h in claude codex; do grep -Eq '"\$sbx" -f "\$profile" /usr/bin/true >/dev/null 2>&1 \|\| \{ echo .*exit 79' "$here/hosts/$h.sh" || s24_pre=0; done
  if [[ $s24_prc -eq 0 && "$work" == *wrote-ok* && "$work" == *42* && "$work" == *ls-ok* && $typo_rc -ne 0 && $s24_pre -eq 1 ]]; then ok=0; else ok=1; fi
  note "24j the profile loads and a normal cell works; a profile with an unknown operation name is rejected by sandbox-exec (rc $typo_rc), and both adapters preflight the profile and exit 79 instead of running the CLI" $ok "gen=$s24_prc work=[$(printf %s "$work" | tr '\n' ' ' | cut -c1-120)] typo-rc=$typo_rc preflight-wired=$s24_pre $(head -c 120 "$s24/p.err")"
fi
if darwin_only 24k; then   # the block is ONE delimited block of exactly the audited rules
  nb="$(grep -c '^;; BEGIN ipc-and-signal denies' "$s24_prof")"; ne="$(grep -c '^;; END ipc-and-signal denies' "$s24_prof")"
  blk="$(awk '/^;; BEGIN ipc-and-signal/{on=1;next} /^;; END ipc-and-signal/{on=0} on' "$s24_prof" | tr '\n' '|')"
  want='(deny ipc-posix-shm*)|(deny ipc-posix-sem*)|(deny ipc-sysv-shm)|(deny ipc-sysv-sem)|(deny ipc-sysv-msg)|(deny signal)|(allow signal (target same-sandbox))|(deny mach-lookup (global-name "com.apple.pasteboard.1") (global-name "com.apple.pboard"))|'
  if [[ "$nb" == 1 && "$ne" == 1 && "$blk" == "$want" ]]; then ok=0; else ok=1; fi
  note "24k the IPC/signal denies are ONE delimited block of exactly the audited rules" $ok "begin=$nb end=$ne block=[$blk]"
fi
trap 'rm -rf "$tmp"' EXIT; s24_clean

# ---- 25: a result row never reports usage or a pass the stream did not establish (lib/parse_codex.py, lib/parse_claude.py, run.sh) --------
# provenance: candidate (TTL 2027-06-01), pinning: false -- the contract is the parsers' docstrings; the streams below are written here, not
# captured from a real CLI. Parser cases drive the parsers on fixture files; the run.sh cases use a FAKE codex (our dir first on PATH).
S25="$tmp/s25"; mkdir -p "$S25/bin" "$S25/home" "$S25/realcodex"
CX_A='{"type":"item.completed","item":{"type":"agent_message","text":"ANSWER"}}'
CX_T='{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
cx_w() { printf '%s\n' "$@" >"$S25/in.jsonl"; }
cx_run() { POUT="$(python3 -I -B "$here/lib/parse_codex.py" "$S25/in.jsonl" "$S25/o.txt" "$S25/u.json" 2>/dev/null)"; PRC=$?; }
cl_run() { POUT="$(python3 -I -B "$here/lib/parse_claude.py" "$S25/in.json" "$S25/o.txt" "$S25/u.json" 2>/dev/null)"; PRC=$?; }
uj() { python3 -I -B -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2],"<absent>")))' "$S25/u.json" "$1"; }
ans() { cat "$S25/o.txt"; }
nullu() { [[ "$(uj tokens_in)" == null && "$(uj tokens_out)" == null && "$(uj cost_usd)" == null ]]; }
# 25a a complete valid stream: the answer and the usage
cx_w "$CX_A" "$CX_T"; cx_run
if [[ $PRC -eq 0 && "$(ans)" == ANSWER && "$(uj tokens_in)" == 5 && "$(uj tokens_out)" == 1 && "$(uj cost_usd)" == null && "$(uj usage_error)" == '"<absent>"' ]]; then ok=0; else ok=1; fi
note "25a codex complete valid stream: answer + usage, exit 0, no error key" $ok "rc=$PRC out=$(ans) usage=$(cat "$S25/u.json")"
# 25b no terminal event (what a CLI that exits 0 mid-turn leaves): stream-incomplete, usage NULL (F1: it was 0), no answer; also an empty stream
cx_w "$CX_A"; cx_run; r1=$PRC; p1="$POUT"; n1=0; nullu || n1=1; a1="$(ans)"
: >"$S25/in.jsonl"; cx_run; r2=$PRC; p2="$POUT"
if [[ $r1 -eq 4 && "$p1" == stream-incomplete && $n1 -eq 0 && -z "$a1" && $r2 -eq 4 && "$p2" == stream-incomplete ]] && nullu; then ok=0; else ok=1; fi
note "25b codex no terminal event / empty stream: stream-incomplete (exit 4), tokens null not 0, no answer" $ok "r=$r1,$r2 p=$p1,$p2 usage=$(cat "$S25/u.json")"
# 25c turn.failed and an error event: host-error (exit 6), the message kept, usage null, no answer
cx_w "$CX_A" '{"type":"turn.failed","error":{"message":"quota   exceeded"}}'; cx_run; r1=$PRC; p1="$POUT"; e1="$(uj error)"; n1=0; nullu || n1=1
cx_w '{"type":"error","message":"stream broke"}' "$CX_A" "$CX_T"; cx_run; r2=$PRC; e2="$(uj error)"; a2="$(ans)"
if [[ $r1 -eq 6 && "$p1" == host-error && "$e1" == *"turn.failed: quota exceeded"* && $n1 -eq 0 && $r2 -eq 6 && "$e2" == *"stream broke"* && -z "$a2" ]]; then ok=0; else ok=1; fi
note "25c codex turn.failed / mid-stream error event: host-error (exit 6) with the message, usage null, no answer even when a turn.completed follows" $ok "r=$r1,$r2 e1=$e1 e2=$e2"
# 25d BOM: at the start of the stream it is stripped; before the terminal line only, that line is invalid JSON
printf '\xef\xbb\xbf%s\n%s\n' "$CX_A" "$CX_T" >"$S25/in.jsonl"; cx_run; r1=$PRC; a1="$(ans)"; t1="$(uj tokens_in)"
printf '%s\n\xef\xbb\xbf%s\n' "$CX_A" "$CX_T" >"$S25/in.jsonl"; cx_run; r2=$PRC; p2="$POUT"; n2=0; nullu || n2=1
if [[ $r1 -eq 0 && "$a1" == ANSWER && "$t1" == 5 && $r2 -eq 5 && "$p2" == stream-invalid && $n2 -eq 0 ]]; then ok=0; else ok=1; fi
note "25d codex BOM at the start of the stream is stripped and parsed; a BOM before the terminal line only is stream-invalid (exit 5), usage null" $ok "r=$r1,$r2 ans=$a1 tok=$t1 p2=$p2"
# 25e invalid JSON line, a non-object line, invalid UTF-8: stream-invalid (they used to be skipped silently)
cx_w "$CX_A" '{not json' "$CX_T"; cx_run; r1=$PRC; p1="$POUT"
cx_w "$CX_A" '5' "$CX_T"; cx_run; r2=$PRC
printf '%s\n{"type":"x","v":"\xff\xfe"}\n%s\n' "$CX_A" "$CX_T" >"$S25/in.jsonl"; cx_run; r3=$PRC
if [[ $r1 -eq 5 && "$p1" == stream-invalid && $r2 -eq 5 && $r3 -eq 5 ]] && nullu; then ok=0; else ok=1; fi
note "25e codex invalid JSON line / non-object line / invalid UTF-8 -> stream-invalid (exit 5), usage null" $ok "r=$r1,$r2,$r3"
# 25f usage missing: valid stream, answer STILL delivered, usage null, usage_error set, exit 0 (graded, excluded from cost)
cx_w "$CX_A" '{"type":"turn.completed"}'; cx_run; r1=$PRC; a1="$(ans)"; ue1="$(uj usage_error)"; n1=0; nullu || n1=1
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":5}}'; cx_run; r2=$PRC; a2="$(ans)"; ue2="$(uj usage_error)"
if [[ $r1 -eq 0 && "$a1" == ANSWER && "$ue1" == *missing* && $n1 -eq 0 && $r2 -eq 0 && "$a2" == ANSWER && "$ue2" == *output_tokens* ]] && nullu; then ok=0; else ok=1; fi
note "25f codex usage (or a required usage field) missing: usage-invalid, answer delivered, tokens null, usage_error set, exit 0" $ok "r=$r1,$r2 ue=$ue1,$ue2"
# 25g every required usage field x every invalid value: usage-invalid, answer delivered, all null; the valid boundary 2**53 is accepted
bad=""; cnt=0
for f in input_tokens output_tokens; do
  for v in -1 5.0 '"5"' true false null 1e400 Infinity NaN 1152921504606846976 9007199254740993; do
    if [[ $f == input_tokens ]]; then u="{\"input_tokens\":$v,\"output_tokens\":1}"; else u="{\"input_tokens\":5,\"output_tokens\":$v}"; fi
    cx_w "$CX_A" "{\"type\":\"turn.completed\",\"usage\":$u}"; cx_run; cnt=$((cnt + 1))
    if [[ $PRC -ne 0 || "$(ans)" != ANSWER || "$(uj usage_error)" != *"$f"* ]] || ! nullu; then bad="$bad $f=$v(rc$PRC)"; fi
  done
done
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":9007199254740992,"output_tokens":0}}'; cx_run
if [[ -z "$bad" && $PRC -eq 0 && "$(uj tokens_in)" == 9007199254740992 && "$(uj tokens_out)" == 0 ]]; then ok=0; else ok=1; fi
note "25g codex usage values: negative, 5.0, \"5\", true/false, null, 1e400, Infinity, NaN, 2**60, 2**53+1 -> usage-invalid for each required field ($cnt runs); 2**53 and 0 accepted" $ok "bad=[$bad]"
# 25h optional usage fields: absent is fine; present and invalid is usage-invalid
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1,"cached_input_tokens":-1}}'; cx_run; r1=$PRC; ue1="$(uj usage_error)"
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1,"cached_input_tokens":4,"reasoning_output_tokens":0}}'; cx_run
if [[ $r1 -eq 0 && "$ue1" == *cached_input_tokens* && $PRC -eq 0 && "$(uj tokens_in)" == 5 ]]; then ok=0; else ok=1; fi
note "25h codex optional usage fields: invalid when present (usage-invalid), not required when absent" $ok "ue=$ue1"
# 25i duplicate keys (the usage object, the terminal event): stream-invalid, nothing taken
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1,"input_tokens":1}}'; cx_run; r1=$PRC; p1="$POUT"
cx_w "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1},"usage":{"input_tokens":1,"output_tokens":1}}'; cx_run; r2=$PRC
if [[ $r1 -eq 5 && "$p1" == stream-invalid && $r2 -eq 5 && -z "$(ans)" ]] && nullu; then ok=0; else ok=1; fi
note "25i codex duplicate key in the usage object or the terminal event -> stream-invalid (exit 5)" $ok "r=$r1,$r2"
# 25j existing classes keep their exit code: a second terminal event, data after the terminal event -> 3, usage null (not 0)
cx_w "$CX_A" "$CX_T" "$CX_T"; cx_run; r1=$PRC; p1="$POUT"; n1=0; nullu || n1=1
cx_w "$CX_A" "$CX_T" '{"type":"item.completed","item":{"type":"agent_message","text":"FORGED"}}'; cx_run; r2=$PRC
if [[ $r1 -eq 3 && "$p1" == stream-trailing-data && $n1 -eq 0 && $r2 -eq 3 && -z "$(ans)" ]]; then ok=0; else ok=1; fi
note "25j codex two terminal events / data after the terminal event: stream-trailing-data (exit 3), usage null" $ok "r=$r1,$r2"
# 25k a 20 MB line: bounded time and memory (the driver kills it at 20 s and reports peak RSS of the child)
python3 -I -B -c 'import json,sys
big={"type":"item.completed","item":{"type":"command_execution","command":"A"*(20*1024*1024)}}
with open(sys.argv[1],"w") as f:
    f.write(json.dumps(big)+"\n"+sys.argv[2]+"\n"+sys.argv[3]+"\n")' "$S25/in.jsonl" "$CX_A" "$CX_T"
big="$(python3 -I -B -c 'import resource,subprocess,sys,time
t=time.time()
try:
    r=subprocess.run([sys.executable,"-I","-B",sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]],timeout=20,capture_output=True)
    rc=r.returncode
except subprocess.TimeoutExpired:
    rc="timeout"
rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
rss=rss/(1024*1024) if sys.platform=="darwin" else rss/1024
print(rc, "%.1f" % (time.time()-t), int(rss))' "$here/lib/parse_codex.py" "$S25/in.jsonl" "$S25/o.txt" "$S25/u.json")"
read -r brc bsec bmb <<<"$big"
if [[ "$brc" == 0 && "$(ans)" == ANSWER && "${bmb:-9999}" -lt 400 ]]; then ok=0; else ok=1; fi
note "25k codex a 20 MB event line is parsed in bounded time and memory (rc $brc, ${bsec:-?}s, peak ${bmb:-?} MB < 400)" $ok "big=[$big]"
rm -f "$S25/in.jsonl"

# Claude: ONE JSON object
CL_OK='{"result":"OK","is_error":false,"total_cost_usd":0.5,"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":7}}'
cl_w() { printf '%s' "$1" >"$S25/in.json"; }
cl_w "$CL_OK"; cl_run
if [[ $PRC -eq 0 && "$(ans)" == OK && "$(uj tokens_in)" == 1103 && "$(uj tokens_out)" == 7 && "$(uj cost_usd)" == 0.5 ]]; then ok=0; else ok=1; fi
note "25l claude one valid document: answer, tokens, cost" $ok "rc=$PRC usage=$(cat "$S25/u.json")"
# 25m an array (even of one result), two concatenated documents, trailing garbage, empty: error classes, usage null, no answer
cl_w "[$CL_OK,$CL_OK]"; cl_run; r1=$PRC; p1="$POUT"; n1=0; nullu || n1=1
cl_w "[{\"type\":\"result\"},$CL_OK]"; cl_run; r1b=$PRC
cl_w "$CL_OK$CL_OK"; cl_run; r2=$PRC
cl_w "$CL_OK
$CL_OK"; cl_run; r2b=$PRC
cl_w "$CL_OK garbage"; cl_run; r3=$PRC; a3="$(ans)"
cl_w '   '; cl_run; r4=$PRC; p4="$POUT"
if [[ $r1 -eq 5 && "$p1" == stream-invalid && $n1 -eq 0 && $r1b -eq 5 && $r2 -eq 5 && $r2b -eq 5 && $r3 -eq 5 && -z "$a3" && $r4 -eq 4 && "$p4" == stream-incomplete ]] && nullu; then ok=0; else ok=1; fi
note "25m claude an array / two documents / trailing garbage -> stream-invalid (exit 5); empty output -> stream-incomplete (exit 4); usage null" $ok "r=$r1,$r1b,$r2,$r2b,$r3,$r4"
# 25n cost_usd: negative, string, bool, NaN, Infinity, 1e400 -> usage-invalid: answer delivered, ALL usage null, usage_error set, exit 0; absent/null -> cost null, tokens kept
bad=""
for v in -0.1 '"0.1"' true NaN Infinity -Infinity 1e400; do
  cl_w "{\"result\":\"OK\",\"is_error\":false,\"total_cost_usd\":$v,\"usage\":{\"input_tokens\":3,\"output_tokens\":7}}"; cl_run
  if [[ $PRC -ne 0 || "$(ans)" != OK || "$(uj usage_error)" != *total_cost_usd* ]] || ! nullu; then bad="$bad $v(rc$PRC)"; fi
done
cl_w '{"result":"OK","is_error":false,"usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; c1="$(uj cost_usd) $(uj tokens_in)"
cl_w '{"result":"OK","is_error":false,"total_cost_usd":null,"usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; c2="$(uj cost_usd) $(uj tokens_in)"
if [[ -z "$bad" && "$c1" == "null 3" && "$c2" == "null 3" ]]; then ok=0; else ok=1; fi
note "25n claude total_cost_usd negative / string / true / NaN / Infinity / 1e400 -> usage-invalid (answer delivered, all usage null); absent or null -> cost null with tokens kept" $ok "bad=[$bad] c=[$c1],[$c2]"
# 25o claude usage fields: missing usage, missing/invalid token fields -> usage-invalid; a bool/float/negative/string/null token
bad=""
for u in '{}' '{"input_tokens":3}' '{"input_tokens":true,"output_tokens":1}' '{"input_tokens":3,"output_tokens":1.0}' '{"input_tokens":-3,"output_tokens":1}' '{"input_tokens":"3","output_tokens":1}' '{"input_tokens":3,"output_tokens":null}' '{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":-1}' '{"input_tokens":9007199254740993,"output_tokens":1}' 'null'; do
  cl_w "{\"result\":\"OK\",\"is_error\":false,\"usage\":$u}"; cl_run
  if [[ $PRC -ne 0 || "$(ans)" != OK || -z "$(uj usage_error | tr -d '"')" ]] || ! nullu; then bad="$bad $u(rc$PRC)"; fi
done
if [[ -z "$bad" ]]; then ok=0; else ok=1; fi
note "25o claude usage missing / required token field missing or not an integer in [0,2**53] -> usage-invalid, answer delivered, tokens null" $ok "bad=[$bad]"
# 25p is_error / error subtype -> host-error (exit 6) with the message, no answer; a non-boolean is_error -> stream-invalid
cl_w '{"result":"credit  balance too low","is_error":true,"usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; r1=$PRC; p1="$POUT"; e1="$(uj error)"; a1="$(ans)"; n1=0; nullu || n1=1
cl_w '{"result":"x","is_error":false,"subtype":"error_max_turns","usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; r2=$PRC
cl_w '{"result":"x","is_error":"false","usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; r3=$PRC
if [[ $r1 -eq 6 && "$p1" == host-error && "$e1" == *"credit balance too low"* && -z "$a1" && $n1 -eq 0 && $r2 -eq 6 && $r3 -eq 5 ]]; then ok=0; else ok=1; fi
note "25p claude is_error / error subtype -> host-error (exit 6) with the message, no answer, usage null; is_error \"false\" (a string) -> stream-invalid" $ok "r=$r1,$r2,$r3 e1=$e1"
# 25q duplicate keys (top level, usage object) -> stream-invalid
cl_w '{"result":"OK","result":"FORGED","is_error":false,"usage":{"input_tokens":3,"output_tokens":7}}'; cl_run; r1=$PRC
cl_w '{"result":"OK","is_error":false,"usage":{"input_tokens":3,"output_tokens":7,"output_tokens":1}}'; cl_run; r2=$PRC
if [[ $r1 -eq 5 && $r2 -eq 5 && -z "$(ans)" ]] && nullu; then ok=0; else ok=1; fi
note "25q claude duplicate key at the top level or in usage -> stream-invalid (exit 5)" $ok "r=$r1,$r2"
rm -f "$S25/in.json"

# run.sh level: a FAKE codex (stream from $S25/stream, exit code from $S25/rc, stderr line from $S25/errline); no sandbox, grader skipped
# (what the cell leaves is judged: a stream-class error is the row error; a usage-invalid row gets as far as grading, so it says grader-skipped)
cat >"$S25/bin/codex" <<'FAKE'
#!/bin/sh
D="$(cd "$(dirname "$0")/.." && pwd)"
cat >/dev/null
[ -s "$D/errline" ] && cat "$D/errline" >&2
cat "$D/stream"
exit "$(cat "$D/rc")"
FAKE
chmod +x "$S25/bin/codex"
printf '#!/bin/sh\necho "s25 fake claude: not expected to run" >&2; exit 97\n' >"$S25/bin/claude"; chmod +x "$S25/bin/claude"
s25n=0
s25run() { # s25run <rc> [errline] ; the stream is $S25/stream -> row in $S25R.jsonl, run.sh exit in $S25RC
  S25R="$tmp/s25r$((++s25n))"; mkdir -p "$S25R"; printf '%s\n' "$1" >"$S25/rc"; printf '%s' "${2:-}" >"$S25/errline"
  inroot "$S25R"
  PATH="$S25/bin:$PATH" command -v codex claude >"$S25R.which"
  env CODEX_API_KEY=k EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 PATH="$S25/bin:$PATH" HOME="$S25/home" TMPDIR="$S25R" \
    EVAL_CODEX_REAL_HOME="$S25/realcodex" EVAL_SKILLS_ROOT="$skills" \
    bash "$here/run.sh" --task "$good" --arm bare --host codex --rep 1 --out "$S25R.jsonl" >"$S25R.out" 2>"$S25R.err"
  S25RC=$?
}
f25() { rowval "$S25R.jsonl" "$1"; }
fake_ok=0; grep -q "^$S25/bin/codex$" <<<"$(PATH="$S25/bin:$PATH" command -v codex)" || fake_ok=1
# 25r F1: the CLI exits 0 WITHOUT a terminal event -> an ERROR row (stream-incomplete), pass false, tokens null (it was 0)
printf '%s\n' "$CX_A" >"$S25/stream"; s25run 0
if [[ $fake_ok -eq 0 && $S25RC -eq 0 && "$(f25 error)" == stream-incomplete && "$(f25 pass)" == false && "$(f25 tokens_in)" == None && "$(f25 tokens_out)" == None && "$(f25 cost_usd)" == None ]]; then ok=0; else ok=1; fi
note "25r run.sh: a CLI that exits 0 with no terminal event -> row error stream-incomplete, pass false, tokens/cost null (not 0)" $ok "rc=$S25RC fake=$fake_ok row: $(cut -c1-300 "$S25R.jsonl" 2>&1)"
# 25s a stream failure is not graded: error is the class, no grader metrics in the row
printf '%s\n' "$CX_A" '{"type":"turn.failed","error":{"message":"quota exceeded"}}' >"$S25/stream"; s25run 0; e1="$(f25 error)"; p1="$(f25 pass)"; t1="$(f25 tokens_in)"
printf '%s\n' "$CX_A" '{bad' "$CX_T" >"$S25/stream"; s25run 0; e2="$(f25 error)"; p2="$(f25 pass)"
printf '%s\n' "$CX_A" "$CX_T" "$CX_T" >"$S25/stream"; s25run 0; e3="$(f25 error)"; t3="$(f25 tokens_in)"
if [[ "$e1" == "host-error: turn.failed: quota exceeded" && "$p1" == false && "$t1" == None && "$e2" == stream-invalid && "$p2" == false && "$e3" == stream-trailing-data && "$t3" == None && "$(f25 metrics)" == "{}" ]]; then ok=0; else ok=1; fi
note "25s run.sh: turn.failed -> host-error with the message, invalid line -> stream-invalid, second terminal -> stream-trailing-data; pass false, tokens null, not graded (no metrics)" $ok "e=[$e1] [$e2] [$e3] t=[$t1] [$t3]"
# 25t usage-invalid: the row is NOT a stream error (it reaches the grading stage: grader-skipped here), carries usage_error, tokens null
printf '%s\n' "$CX_A" '{"type":"turn.completed","usage":{"input_tokens":-5,"output_tokens":1}}' >"$S25/stream"; s25run 0
if [[ $S25RC -eq 0 && "$(f25 error)" == grader-skipped && "$(f25 usage_error)" == *input_tokens* && "$(f25 tokens_in)" == None && "$(f25 tokens_out)" == None && "$(f25 exit)" == 0 ]]; then ok=0; else ok=1; fi
note "25t run.sh: a valid answer with an invalid usage field -> not a stream error (reaches grading), row has usage_error, tokens null, host exit 0" $ok "row: $(cut -c1-300 "$S25R.jsonl" 2>&1)"
# 25u a crashed CLI (exit 1, partial stream, a stderr line): tokens null, pass false, the host exit is the error
printf '%s\n' "$CX_A" >"$S25/stream"; s25run 1 "fatal: crashed"
if [[ "$(f25 tokens_in)" == None && "$(f25 tokens_out)" == None && "$(f25 pass)" == false && "$(f25 error)" == "host exit"* ]]; then ok=0; else ok=1; fi
note "25u run.sh: a crashed CLI (exit 1, partial stream) -> tokens null, pass false, error is the host exit" $ok "row: $(cut -c1-300 "$S25R.jsonl" 2>&1)"
# 25v control: a complete valid stream keeps its usage (and is not a stream error)
printf '%s\n' "$CX_A" "$CX_T" >"$S25/stream"; s25run 0
if [[ "$(f25 tokens_in)" == 5 && "$(f25 tokens_out)" == 1 && "$(f25 error)" == grader-skipped && "$(f25 usage_error)" == "<absent>" ]]; then ok=0; else ok=1; fi
note "25v run.sh control: a complete valid stream -> tokens 5/1, no usage_error" $ok "row: $(cut -c1-300 "$S25R.jsonl" 2>&1)"
# 25w every run above resolved codex AND claude into our scratch (never the real CLIs)
real25=""; for w in "$tmp"/s25r*.which; do [[ "$(sed -n 1p "$w")" == "$S25/bin/codex" && "$(sed -n 2p "$w")" == "$S25/bin/claude" ]] || real25="$real25 $w"; done
if [[ -z "$real25" ]] && ls "$tmp"/s25r*.which >/dev/null 2>&1; then ok=0; else ok=1; fi
note "25w the fake codex and claude resolved first on PATH for every run.sh case above" $ok "not-fake: $real25"

# 25x report.py: a row with null usage is excluded from the token mean and counted (n_usage_missing); the warning when an arm's share is over the threshold
python3 -I -B - "$S25/rep.jsonl" "$S25/rep2.jsonl" <<'PY'
import json, sys
def rows(arm, toks):
    for i, t in enumerate(toks):
        yield {"task": "t%d" % i, "skill": "prod-ops", "split": "dev", "kind": "seeded", "language": "go", "arm": arm, "host": "codex", "model": "m",
               "rep": 1, "pass": True, "metrics": {}, "duration_s": 1.0, "tokens_in": t, "tokens_out": None if t is None else 50}
with open(sys.argv[1], "w") as o:
    for r in list(rows("skill", [100, 200, None])) + list(rows("bare", [100, 100, 100])):
        o.write(json.dumps(r) + "\n")
with open(sys.argv[2], "w") as o:
    for r in list(rows("skill", [100, 200, 300, 400, 500])) + list(rows("bare", [100, 100, 100, 100, None])):   # 1 of 5 = 20%: not over the threshold
        o.write(json.dumps(r) + "\n")
PY
rp="$(python3 -I -B "$here/report.py" "$S25/rep.jsonl" 2>&1)"; rp2="$(python3 -I -B "$here/report.py" "$S25/rep2.jsonl" 2>&1)"
sl="$(grep -E '^prod-ops +codex +m +n/a +dev +go +seeded +skill ' <<<"$rp")"
nm="$(python3 -I -B -c 'import sys;sys.path.insert(0,sys.argv[1]);import report,json
rows=[json.loads(l) for l in open(sys.argv[2])];print(report.cell([r for r in rows if r["arm"]=="skill"])["n_usage_missing"])' "$here" "$S25/rep.jsonl")"
if [[ "$sl" == *"200 (1 no usage)"* && "$nm" == 1 && "$rp" == *"WARNING"*"1 of 3 skill rows have no usage"* && "$rp2" != *"rows have no usage"* ]]; then ok=0; else ok=1; fi
note "25x report: rows with null usage are excluded from the token figure ((150+250) over the 2 rows with usage / 2 passing = 200) and counted (n_usage_missing 1); an arm over 20% missing prints a WARNING, an arm at 20% does not" $ok "line=[$sl] n=$nm warn=$(grep -c 'rows have no usage' <<<"$rp")/$(grep -c 'rows have no usage' <<<"$rp2")"

# ---- 26: the third review's warnings: HUP, the git-metadata digest, the host list, cell lifetime vs the sweep, a graded Codex pass ----
# Own fakes (hang-capable, pid-recording) first on PATH; path26 aborts the whole suite (exit 97) when codex/claude do not resolve into them.
S26="$tmp/s26"; mkdir -p "$S26/bin" "$S26/realcodex" "$S26/realclaude" "$S26/home"; S26_PATHCHK=0
S26CANARY="S26-CRED-CANARY-5521"
printf '{"canary":"%s"}\n' "$S26CANARY" >"$S26/realcodex/auth.json"; chmod 600 "$S26/realcodex/auth.json"
echo "do the thing" >"$S26/prompt.txt"
cat >"$S26/bin/codex" <<FAKE
#!/usr/bin/env bash
cat >/dev/null; : >"$S26/invoked" 2>/dev/null
if [ -f "$S26/hang" ]; then echo \$\$ >"$S26/cli.pid"; echo ready >"$S26/ready.fifo"; exec sleep 30; fi
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
FAKE
cat >"$S26/bin/claude" <<FAKE
#!/usr/bin/env bash
cat >/dev/null; : >"$S26/invoked" 2>/dev/null
if [ -f "$S26/hang" ]; then echo \$\$ >"$S26/cli.pid"; echo ready >"$S26/ready.fifo"; exec sleep 30; fi
echo '{"result":"OK","is_error":false,"total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":2}}'
FAKE
chmod +x "$S26/bin/codex" "$S26/bin/claude"
path26() {
  local c; c="$(PATH="$S26/bin:$PATH" command -v codex claude | tr '\n' ' ')"
  [[ "$c" == "$S26/bin/codex $S26/bin/claude " ]] || { echo "selftest: FATAL: codex/claude do not resolve into $S26/bin (got: $c)" >&2; exit 97; }
  S26_PATHCHK=$((S26_PATHCHK + 1))
}
# runhang26 <signal> <pid|group> <cmd...>: run cmd in the background (group: as the leader of its OWN session, so `kill -<sig> -<pgid>` from
# here is a terminal hangup that does not reach this test), wait for the fake CLI to say it is running, send the signal, collect:
# R26RC (exit code of cmd), R26READY, R26ALIVE (the fake CLI is still alive afterwards: it is killed here either way)
runhang26() {
  local sig="$1" tgt="$2" cxpid; shift 2
  rm -f "$S26/cli.pid" "$S26/ready.fifo"; mkfifo "$S26/ready.fifo"; exec 7<>"$S26/ready.fifo"; : >"$S26/hang"
  path26; inroot
  if [[ "$tgt" == group ]]; then python3 -I -B -c 'import os,sys;os.setsid();os.execvp(sys.argv[1],sys.argv[1:])' "$@" >"$S26/h.out" 2>"$S26/h.err" &
  else "$@" >"$S26/h.out" 2>"$S26/h.err" & fi
  local pid=$!
  if read -r -t 20 -u 7 _r; then R26READY=yes; else R26READY=never-started; fi
  if [[ "$tgt" == group ]]; then kill -s "$sig" -- "-$pid" 2>/dev/null; else kill -s "$sig" "$pid" 2>/dev/null; fi
  wait "$pid"; R26RC=$?; exec 7<&-; rm -f "$S26/hang"
  cxpid="$(cat "$S26/cli.pid" 2>/dev/null)"; R26ALIVE=no
  if [[ -n "$cxpid" ]] && kill -0 "$cxpid" 2>/dev/null; then R26ALIVE=yes; kill -TERM "$cxpid" 2>/dev/null; fi
}
s26dirs() { rm -rf "${S26:?}/${1:?}"; mkdir -p "$S26/$1/w" "$S26/$1/h" "$S26/$1/g"; }
# W1 a: HUP to the codex adapter mid-run (14n6 is the TERM twin): the CLI dies, the staged copy is gone, rc 129
s26dirs a1
runhang26 HUP pid env -u CODEX_API_KEY EVAL_NO_SANDBOX=1 PATH="$S26/bin:$PATH" HOME="$S26/home" EVAL_GOCACHE="$S26/a1/g" EVAL_CODEX_REAL_HOME="$S26/realcodex" \
  bash "$here/hosts/codex.sh" "$S26/a1/w" "$S26/a1/h" "$S26/prompt.txt" "$S26/a1/out" "$S26/a1/usage" "" 0.5 read-only ""
if [[ "$R26READY" == yes && $R26RC -eq 129 && "$R26ALIVE" == no && -z "$(grep -rl "$S26CANARY" "$S26/a1" 2>/dev/null)" && -z "$(find "$S26/a1" -maxdepth 1 -name 'sbx.*' | head -1)" ]]; then ok=0; else ok=1; fi
note "26a codex adapter: SIGHUP mid-run kills the CLI, scrubs the staged copy and the adapter dir, exit 129" $ok "ready=$R26READY rc=$R26RC cli-alive=$R26ALIVE left: $(find "$S26/a1" -mindepth 1 -maxdepth 2 | head -5 | tr '\n' ' ')"
# W1 b: the claude adapter ran limited.py in the FOREGROUND with no trap: TERM or HUP killed bash and left the watchdog + CLI running
for sg in TERM:143 HUP:129; do
  s26dirs b1
  runhang26 "${sg%%:*}" pid env -u ANTHROPIC_API_KEY EVAL_CLAUDE_NO_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN="$S26CANARY-T" PATH="$S26/bin:$PATH" HOME="$S26/home" EVAL_GOCACHE="$S26/b1/g" \
    bash "$here/hosts/claude.sh" "$S26/b1/w" "$S26/b1/h" "$S26/prompt.txt" "$S26/b1/out" "$S26/b1/usage" "" 0.5 read-only ""
  if [[ "$R26READY" == yes && $R26RC -eq "${sg##*:}" && "$R26ALIVE" == no && -z "$(find "$S26/b1" -maxdepth 1 -name 'sbx.*' | head -1)" ]]; then ok=0; else ok=1; fi
  note "26b/${sg%%:*} claude adapter: ${sg%%:*} mid-run kills the CLI (its watchdog included) and removes the adapter dir, exit ${sg##*:}" $ok "ready=$R26READY rc=$R26RC cli-alive=$R26ALIVE left: $(find "$S26/b1" -mindepth 1 -maxdepth 1 | head -5 | tr '\n' ' ')"
done
# W1 c: HUP (and, as the control, TERM) to the watchdog itself: the child's group is killed and reaped, 129 / 143
for sg in HUP:129 TERM:143; do
  runhang26 "${sg%%:*}" pid python3 -I -B "$here/lib/limited.py" 60 -- "$S26/bin/codex"
  if [[ "$R26READY" == yes && $R26RC -eq "${sg##*:}" && "$R26ALIVE" == no ]]; then ok=0; else ok=1; fi
  note "26c/${sg%%:*} lib/limited.py: ${sg%%:*} to the watchdog kills the child's process group and exits ${sg##*:}" $ok "ready=$R26READY rc=$R26RC child-alive=$R26ALIVE"
done
# W1 d/e: run.sh. d = HUP to run.sh alone; e = HUP to the whole process group of run.sh (a terminal hangup: run.sh AND its watchdog get it, the
# adapter and the CLI are in their own sessions and do not). Either way: CLI dead, the cell gone, the credential nowhere, exit 129.
gt26="$(mktask "$S26/corp" prod-review t-hup dev always0)"
for hm in pid:d group:e; do
  rm -rf "$S26/t${hm##*:}"; mkdir -p "$S26/t${hm##*:}"
  runhang26 HUP "${hm%%:*}" env CODEX_API_KEY="$S26CANARY-KEY-VALUE" EVAL_NO_SANDBOX=1 EVAL_SKIP_GRADER=1 EVAL_CODEX_REAL_HOME="$S26/realcodex" PATH="$S26/bin:$PATH" HOME="$S26/home" \
    TMPDIR="$S26/t${hm##*:}" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gt26" --arm bare --host codex --rep 1 --out "$S26/hup${hm##*:}.jsonl"
  if [[ "$R26READY" == yes && $R26RC -eq 129 && "$R26ALIVE" == no && -z "$(find "$S26/t${hm##*:}" -mindepth 1 | head -1)" && -z "$(grep -rl "$S26CANARY" "$S26/t${hm##*:}" 2>/dev/null)" ]]; then ok=0; else ok=1; fi
  note "26${hm##*:} run.sh: SIGHUP to ${hm%%:*}$([[ ${hm%%:*} == group ]] && echo ' (the whole foreground group, as a hangup)') mid-run: CLI dead, cell removed, credential nowhere, exit 129" $ok "ready=$R26READY rc=$R26RC cli-alive=$R26ALIVE left: $(find "$S26/t${hm##*:}" -mindepth 1 -maxdepth 2 | head -4 | tr '\n' ' ') err: $(tail -n 2 "$S26/h.err" | cut -c1-160 | tr '\n' ' ')"
done

# ---- W4: the digest that decides workdir-tampered covers the git metadata of the WHOLE tree (stub host, sandbox n/a, graded: a mutation of
# the workdir while the host "ran" must give workdir-tampered, never a grade). Each script gets the workdir as $1.
gd26="$(mktask "$S26/gcorp" prod-review t-dig dev always0)"; mkdir -p "$S26/t4"
s26mut() { # s26mut <name> <script body>: write the mutation script
  { echo '#!/usr/bin/env bash'; echo 'export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1'; echo 'cd "$1" || exit 1'; printf '%s\n' "$2"; } >"$S26/m-$1.sh"
}
s26mut nested-config 'mkdir -p sub/.git; printf "[core]\n\tfsmonitor = false\n" >sub/.git/config'
s26mut nested-deep 'mkdir -p a/b/c/.git; echo x >a/b/c/.git/config'
s26mut gitfile 'mkdir -p sub; echo "gitdir: ../elsewhere" >sub/.git'
s26mut gitfile-link 'mkdir -p sub; ln -s /nonexistent-target sub/.git'
s26mut index 'echo new >new.txt; git add new.txt'
s26mut hook 'printf "#!/bin/sh\n" >.git/hooks/post-checkout; chmod +x .git/hooks/post-checkout'
s26mut info-attributes 'mkdir -p .git/info; echo "* filter=x" >.git/info/attributes'
s26mut alternates 'mkdir -p .git/objects/info; echo /nowhere >.git/objects/info/alternates'
s26mut subdir-gitattributes 'mkdir -p sub; echo "* filter=x" >sub/.gitattributes'
s26mut gitmodules 'printf "[submodule \"a\"]\n\tpath = a\n" >.gitmodules'
s26mut head 'echo "ref: refs/heads/other" >.git/HEAD'
s26mut ref 'git update-ref refs/heads/zz HEAD'
s26mut gitdir-config-worktree 'echo "[core]" >.git/config.worktree'
s26mut modules 'mkdir -p .git/modules/m/hooks; echo x >.git/modules/m/hooks/pre-commit'
# controls: content is not git metadata
s26mut ctl-untracked 'echo hi >untracked.txt; mkdir -p deep/dir; echo hi >deep/dir/f.txt; echo more >>README.md'
s26mut ctl-objects 'mkdir -p .git/objects/zz; echo junk >.git/objects/zz/obj'
for dm in nested-config nested-deep gitfile gitfile-link index hook info-attributes alternates subdir-gitattributes gitmodules head ref gitdir-config-worktree modules; do
  inroot; rm -f "$S26/dg-$dm.jsonl"
  env STUB_MODE=solve STUB_SOLVE_CMD="$S26/m-$dm.sh" TMPDIR="$S26/t4" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host stub --rep 1 --out "$S26/dg-$dm.jsonl" >/dev/null 2>&1; rc=$?
  if [[ $rc -eq 0 && "$(rowval "$S26/dg-$dm.jsonl" error)" == workdir-tampered && "$(rowval "$S26/dg-$dm.jsonl" pass)" == false ]]; then ok=0; else ok=1; fi
  note "26f/$dm digest: '$dm' added while the CLI ran -> workdir-tampered, not graded" $ok "rc=$rc row: $(cut -c1-220 "$S26/dg-$dm.jsonl" 2>&1)"
done
for dm in ctl-untracked ctl-objects; do
  inroot; rm -f "$S26/dg-$dm.jsonl"
  env STUB_MODE=solve STUB_SOLVE_CMD="$S26/m-$dm.sh" TMPDIR="$S26/t4" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host stub --rep 1 --out "$S26/dg-$dm.jsonl" >/dev/null 2>&1; rc=$?
  if [[ $rc -eq 0 && "$(rowval "$S26/dg-$dm.jsonl" error)" == "<absent>" && "$(rowval "$S26/dg-$dm.jsonl" pass)" == true ]]; then ok=0; else ok=1; fi
  note "26f/$dm digest control: $([[ $dm == ctl-objects ]] && echo 'a new loose object (objects/ is data, not covered)' || echo 'untracked and edited content files (not git metadata)') does NOT change it: graded, pass:true" $ok "rc=$rc row: $(cut -c1-220 "$S26/dg-$dm.jsonl" 2>&1)"
done
# the digest is read-only and deterministic: twice over the same tree gives the same value; a tree it cannot open gives no digest (the caller fails closed)
dw="$S26/dw"; rm -rf "$dw"; mkdir -p "$dw/sub"; ( cd "$dw" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q . && echo a >f && git add -A && git -c user.name=e -c user.email=e@e.invalid commit -q -m i ) >/dev/null 2>&1
d1="$(python3 -I -B "$here/lib/scrub.py" gitdigest "$dw")"; d2="$(python3 -I -B "$here/lib/scrub.py" gitdigest "$dw")"; python3 -I -B "$here/lib/scrub.py" gitdigest "$S26/no-such-dir" >/dev/null 2>&1; drc=$?
ln -s "$dw" "$S26/dw-link"; python3 -I -B "$here/lib/scrub.py" gitdigest "$S26/dw-link" >/dev/null 2>&1; lrc=$?
if [[ ${#d1} -eq 64 && "$d1" == "$d2" && $drc -eq 1 && $lrc -eq 1 ]]; then ok=0; else ok=1; fi
note "26f/det digest: deterministic, 64 hex; a missing dir and a symlinked root give exit 1 and no digest" $ok "d1=$d1 d2=$d2 missing-rc=$drc symlink-rc=$lrc"

# ---- W5: the host is an explicit list; nothing is created for anything else
for hv in nope ../lib/live '' CODEX 'codex ' 'a/b' '..' 'stub.sh'; do
  rm -rf "$S26/t5"; mkdir -p "$S26/t5"; inroot "$S26/t5"; rm -f "$S26/r5.jsonl"
  env TMPDIR="$S26/t5" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host "$hv" --rep 1 --out "$S26/r5.jsonl" >"$S26/r5.out" 2>"$S26/r5.err"; rc=$?
  if [[ $rc -eq 2 && -z "$(find "$S26/t5" -mindepth 1 | head -1)" && ! -e "$S26/r5.jsonl" ]] && grep -q 'host must be one of' "$S26/r5.err"; then ok=0; else ok=1; fi
  note "26g/host '$hv' is refused: exit 2, nothing created (no cell, no row)" $ok "rc=$rc left: $(find "$S26/t5" -mindepth 1 | head -2 | tr '\n' ' ') err: $(head -c 120 "$S26/r5.err")"
done
inroot; rm -f "$S26/r5.jsonl"
env TMPDIR="$S26/t5" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host stub --rep 1 --preflight >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then ok=0; else ok=1; fi
note "26g/control the listed host 'stub' still passes the check (preflight exit 0)" $ok "rc=$rc"

# ---- W7 (a): the longest possible cell must stay under the sweep floor minus the margin: timeout_s < 1170, so 1169 is the largest
for tv in 1169:0 1169.9:0 1170:2 3600:2 0:2 -5:2 1e9:2 \"abc\":2; do
  tk="$(TASK_TIMEOUT="${tv%%:*}" mktask "$S26/tcorp$RANDOM" prod-review t-to dev always0)"; inroot; rm -rf "$S26/t7a"; mkdir -p "$S26/t7a"
  env TMPDIR="$S26/t7a" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$tk" --arm bare --host stub --rep 1 --preflight >/dev/null 2>"$S26/r7.err"; rc=$?
  if [[ $rc -eq ${tv##*:} ]] && { [[ $rc -eq 0 ]] || [[ "$(grep -c . "$S26/r7.err")" == 1 ]]; } && [[ -z "$(find "$S26/t7a" -mindepth 1 | head -1)" ]]; then ok=0; else ok=1; fi
  note "26h/timeout_s=${tv%%:*} -> exit ${tv##*:} ($([[ ${tv##*:} == 0 ]] && echo accepted || echo 'refused, one line'))" $ok "rc=$rc err: $(head -c 200 "$S26/r7.err")"
done
# W7 (b): the sweep spares a cell whose marker names a live pid with its own start time; everything else follows the age rule
s26old() { mkdir -p "$1/home"; echo x >"$1/home/f"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" >"$1/.eval-live"; python3 -I -B -c 'import os,sys,time;t=time.time()-5*3600;os.utime(sys.argv[1],(t,t))' "$1"; }
s26lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }
rm -rf "$S26/t7"; mkdir -p "$S26/t7"
sleep 300 & hl=$!; sleep 300 & hd=$!; hlst="$(s26lstart "$hl")"; hdst="$(s26lstart "$hd")"; kill -TERM "$hd" 2>/dev/null; wait "$hd" 2>/dev/null
s26old "$S26/t7/eval-cell.live" "$(printf '%s\n%s' "$hl" "$hlst")"
s26old "$S26/t7/eval-cell.dead" "$(printf '%s\n%s' "$hd" "$hdst")"
s26old "$S26/t7/eval-cell.reuse" "$(printf '%s\n%s' "$hl" "Mon Jan  1 00:00:00 2001")"
s26old "$S26/t7/eval-cell.nomarker" ""
s26old "$S26/t7/eval-cell.garbage" "not a marker"
s26old "$S26/t7/eval-cell.pidonly" "$hl"
s26old "$S26/t7/eval-cell.fresh" "$(printf '%s\n%s' "$hd" "$hdst")"; python3 -I -B -c 'import os,sys,time;os.utime(sys.argv[1],(time.time(),time.time()))' "$S26/t7/eval-cell.fresh"
inroot; env STUB_MODE=noop TMPDIR="$S26/t7" EVAL_SWEEP_MINUTES=30 EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host stub --rep 1 --out "$S26/r7.jsonl" >/dev/null 2>"$S26/r7s.err"
kill -TERM "$hl" 2>/dev/null; wait "$hl" 2>/dev/null
gone() { [[ ! -e "$S26/t7/eval-cell.$1" ]] && echo gone || echo kept; }
if [[ "$(gone live)" == kept && "$(gone dead)" == gone && "$(gone reuse)" == gone && "$(gone nomarker)" == gone && "$(gone garbage)" == gone && "$(gone pidonly)" == gone && "$(gone fresh)" == kept ]]; then ok=0; else ok=1; fi
note "26i sweep: an old cell whose marker names a LIVE pid with its own start time is kept; dead pid, reused pid (other start time), no/garbage/pid-only marker are swept; a fresh cell is kept" $ok "live=$(gone live) dead=$(gone dead) reuse=$(gone reuse) nomarker=$(gone nomarker) garbage=$(gone garbage) pidonly=$(gone pidonly) fresh=$(gone fresh)"
# the marker run.sh itself writes: its own pid (read from inside the run, while run.sh is alive) and that pid's start time
cat >"$S26/m-marker.sh" <<'EOF'
#!/usr/bin/env bash
cell="$(dirname "$1")"; cp "$cell/.eval-live" "$S26M/marker.copy"; pid="$(head -n 1 "$cell/.eval-live")"
LC_ALL=C ps -o lstart= -p "$pid" | sed 's/^ *//' >"$S26M/marker.start"; echo "$pid" >"$S26M/marker.pid"
EOF
inroot; rm -f "$S26/marker."*; env S26M="$S26" STUB_MODE=solve STUB_SOLVE_CMD="$S26/m-marker.sh" TMPDIR="$S26/t7" EVAL_SKILLS_ROOT="$skills" bash "$here/run.sh" --task "$gd26" --arm bare --host stub --rep 1 --out "$S26/r7m.jsonl" >/dev/null 2>&1 &
mp=$!; wait "$mp"
if [[ "$(sed -n 1p "$S26/marker.copy" 2>/dev/null)" == "$mp" && "$(sed -n 1p "$S26/marker.pid" 2>/dev/null)" == "$mp" && -n "$(sed -n 2p "$S26/marker.copy")" && "$(sed -n 2p "$S26/marker.copy")" == "$(cat "$S26/marker.start")" ]] \
   && [[ -z "$(find "$S26/t7" -maxdepth 1 -name 'eval-cell.*' -newer "$S26/marker.pid" | head -1)" ]]; then ok=0; else ok=1; fi
note "26j run.sh writes its cell's .eval-live: its own pid and that pid's start time (as ps reports it while alive), and the cell is removed at the end" $ok "marker: $(tr '\n' '|' <"$S26/marker.copy" 2>&1) pid=$mp"

# ---- live.sh names the row's error class for exit 4 (never its content)
rm -rf "$S26/lv"; mkdir -p "$S26/lv"; cp -R "$here/lib" "$S26/lv/lib"
cat >"$S26/lv/run.sh" <<'EOF'
#!/usr/bin/env bash
out=""; pf=0; while [[ $# -gt 0 ]]; do case "$1" in --out) out="$2"; shift 2 ;; --preflight) pf=1; shift ;; *) shift ;; esac; done
[[ $pf -eq 1 ]] && exit 0
printf '{"error":"%s"}\n' "$FAKE_ERR" >>"$out"; exit 4
EOF
for le in 'scrub-failed: /secret/path/x' 'credential-in-output' 'credential-in-kept-files: 3 file(s)' 'credential-scan-failed'; do
  inroot; rm -rf "$S26/lres"
  env EVAL_LIVE=1 EVAL_HOSTS=stub N=1 EVAL_CORPUS="$S26/gcorp" EVAL_RESULTS_DIR="$S26/lres" FAKE_ERR="$le" HOME="$S26/home" bash "$S26/lv/lib/live.sh" >"$S26/lv.out" 2>"$S26/lv.err"; lrc=$?
  cls="${le%%:*}"
  if [[ $lrc -eq 4 ]] && grep -q "row error class: $cls;" "$S26/lv.err" && ! grep -q 'secret/path\|3 file' "$S26/lv.err" && ! grep -q 'credential copy could not be removed' "$S26/lv.err"; then ok=0; else ok=1; fi
  note "26k live.sh exit 4 names the row's error class '$cls' and nothing of the row beyond it" $ok "rc=$lrc err: $(grep 'STOP' "$S26/lv.err" | head -c 240)"
done

# ---- W6: a GRADED Codex pass: the fake codex under the REAL seatbelt adapter, read-only task -> graded, pass:true (macOS)
if darwin_only 26l; then
  inroot; rm -rf "$S26/t6"; mkdir -p "$S26/t6"; rm -f "$S26/r6.jsonl"; path26
  env CODEX_API_KEY=k EVAL_CODEX_REAL_HOME="$S26/realcodex" PATH="$S26/bin:$PATH" HOME="$S26/home" TMPDIR="$S26/t6" EVAL_SKILLS_ROOT="$skills" \
    bash "$here/run.sh" --task "$gd26" --arm bare --host codex --rep 1 --out "$S26/r6.jsonl" >/dev/null 2>"$S26/r6.err"; rc=$?
  if [[ $rc -eq 0 && "$(rowval "$S26/r6.jsonl" pass)" == true && "$(rowval "$S26/r6.jsonl" sandbox)" == seatbelt && "$(rowval "$S26/r6.jsonl" error)" == "<absent>" && "$(rowval "$S26/r6.jsonl" host)" == codex ]]; then ok=0; else ok=1; fi
  note "26l codex under the real seatbelt adapter, read-only task: GRADED, pass:true, sandbox seatbelt (the cell is gradable on macOS)" $ok "rc=$rc row: $(cut -c1-260 "$S26/r6.jsonl" 2>&1) err: $(tail -n 2 "$S26/r6.err" | cut -c1-160 | tr '\n' ' ')"
fi
# Linux sibling: no seatbelt, so the codex adapter refuses before the CLI starts (error sandbox, exit 3, never graded); the unconfined-grader refusal
# for Codex's own sandbox is portable and already asserted by 21f2 (EVAL_NO_SANDBOX=1: grader-unconfined, host never started)
if [[ "$PLATFORM" != Darwin ]]; then
  inroot; rm -rf "$S26/t6"; mkdir -p "$S26/t6"; rm -f "$S26/r6.jsonl" "$S26/invoked"; path26
  env CODEX_API_KEY=k EVAL_CODEX_REAL_HOME="$S26/realcodex" PATH="$S26/bin:$PATH" HOME="$S26/home" TMPDIR="$S26/t6" EVAL_SKILLS_ROOT="$skills" \
    bash "$here/run.sh" --task "$gd26" --arm bare --host codex --rep 1 --out "$S26/r6.jsonl" >/dev/null 2>"$S26/r6.err"; rc=$?
  if [[ $rc -eq 3 && "$(rowval "$S26/r6.jsonl" error)" == sandbox && "$(rowval "$S26/r6.jsonl" pass)" == false && ! -e "$S26/invoked" ]]; then ok=0; else ok=1; fi
  note "26m codex without a seatbelt, no opt-out: the adapter refuses (error sandbox, exit 3), the CLI is never started, nothing graded" $ok "rc=$rc row: $(cut -c1-260 "$S26/r6.jsonl" 2>&1)"
fi
# every run above resolved codex and claude into the section's own fakes
if (( S26_PATHCHK >= 8 )); then ok=0; else ok=1; fi
note "26z every run in this section resolved codex AND claude into $S26/bin first (checks: $S26_PATHCHK)" $ok "checks=$S26_PATHCHK"

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
