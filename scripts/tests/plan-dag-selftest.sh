#!/usr/bin/env bash
# plan-dag-selftest.sh -- hermetic selftest of scripts/plan-dag.py.
# Every plan is a temp file; no network, no repo state read except the tool
# (override with PLAN_DAG=/path/to/copy to prove a mutation RED).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD="${PLAN_DAG:-$HERE/../plan-dag.py}"
T="$(mktemp -d "${TMPDIR:-/tmp}/plan-dag-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# run FILE [ARGS...] -> rc, out (stdout), err (stderr)
run() {
  rc=0
  python3 -I -B "$PD" "$@" >"$T/out" 2>"$T/err" || rc=$?
  out="$(cat "$T/out")"
  err="$(cat "$T/err")"
}
expect_rc() { # label want
  if [ "$rc" = "$2" ]; then ok; else bad "$1: rc=$rc want $2 (out: ${out:0:160} err: ${err:0:160})"; fi
}
has() { # label haystack needle
  case "$2" in *"$3"*) ok ;; *) bad "$1: missing '$3' in: ${2:0:300}" ;; esac
}
hasnt() {
  case "$2" in *"$3"*) bad "$1: unexpected '$3' in: ${2:0:300}" ;; *) ok ;; esac
}
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got '${2:0:300}' want '$3'"; fi; }
plan() { printf '%s' "$2" >"$T/$1"; }

# --- valid diamond ---------------------------------------------------------
plan d.json '{"tasks":[{"id":"d","depends_on":["b","c"],"files":["d.go"]},{"id":"b","depends_on":["a"],"files":["b.go"]},{"id":"a","depends_on":[],"files":["a.go"]},{"id":"c","depends_on":["a"],"files":["c.go"]}]}'
run "$T/d.json" --format json
expect_rc diamond 0
eq diamond-json "$out" '{"ok":true,"waves":[["a"],["b","c"],["d"]],"max_width":2,"critical_path":["a","b","d"],"verify_first":["a","b","c"],"ready":["a"]}'
run "$T/d.json"
expect_rc diamond-text 0
has diamond-text "$out" 'wave 2 (width 2): b [verify-first] c [verify-first]'
has diamond-text "$out" 'critical path (3): a -> b -> d'
has diamond-text "$out" 'max_width=2'
hasnt diamond-d-not-gate "$out" 'd [verify-first]'

run "$T/d.json" --format json --landed a
eq landed-a "$out" '{"ok":true,"waves":[["a"],["b","c"],["d"]],"max_width":2,"critical_path":["a","b","d"],"verify_first":["a","b","c"],"ready":["b","c"]}'
run "$T/d.json" --format json --landed a,b
has landed-ab "$out" '"ready":["c"]'
run "$T/d.json" --format json --landed b
has landed-b-only "$out" '"ready":["a"]'
run "$T/d.json" --landed a,zz
expect_rc landed-unknown 2

# a task whose dependencies sit in different waves lands after the LAST of them
plan e.json '{"tasks":[{"id":"x","depends_on":["a","c"],"files":["x"]},{"id":"c","depends_on":["b"],"files":["c"]},{"id":"b","depends_on":["a"],"files":["b"]},{"id":"a","files":["a"]}]}'
run "$T/e.json" --format json
has multi-wave-deps "$out" '"waves":[["a"],["b"],["c"],["x"]]'
run "$T/e.json" --format json --landed a
has landed-needs-all-deps "$out" '"ready":["b"]'

# --- same file, no dependency -> conflict; with dependency -> serialised ----
plan c1.json '{"tasks":[{"id":"x","files":["src/m.go"]},{"id":"y","files":["src/m.go"]}]}'
run "$T/c1.json"
expect_rc conflict 1
has conflict "$out" 'file_conflict'
has conflict "$out" 'x and y'
has conflict "$out" 'src/m.go'
run "$T/c1.json" --format json
has conflict-json "$out" '{"ok":false,"errors":[{"code":"file_conflict","tasks":["x","y"],"file":"src/m.go"'
hasnt conflict-no-plan "$out" '"waves"'
plan c2.json '{"tasks":[{"id":"x","files":["src/m.go"]},{"id":"y","depends_on":["x"],"files":["src/m.go"]}]}'
run "$T/c2.json"
expect_rc serialised 0
plan c3.json '{"tasks":[{"id":"a","files":["s.go"]},{"id":"b","depends_on":["a"],"files":["t.go"]},{"id":"c","depends_on":["b"],"files":["s.go"]}]}'
run "$T/c3.json"
expect_rc transitive 0
# a transitive dependency must not hide an UNRELATED conflict
plan c4.json '{"tasks":[{"id":"a","files":["s.go"]},{"id":"b","depends_on":["a"],"files":["t.go"]},{"id":"c","depends_on":["b"],"files":["u.go"]},{"id":"z","files":["t.go"]}]}'
run "$T/c4.json"
expect_rc unrelated-conflict 1
has unrelated-conflict "$out" 'b and z'
has unrelated-conflict "$out" 'z'
# conflict when one only reaches the other through a third task in the other direction
plan c5.json '{"tasks":[{"id":"a","depends_on":["c"],"files":["s.go"]},{"id":"b","files":["t.go"]},{"id":"c","depends_on":["b"],"files":["u.go"]},{"id":"d","files":["s.go"]}]}'
run "$T/c5.json"
expect_rc rev-transitive 1
has rev-transitive "$out" 'a and d'

# --- structural errors ------------------------------------------------------
plan cy.json '{"tasks":[{"id":"a","depends_on":["c"],"files":["a"]},{"id":"b","depends_on":["a"],"files":["b"]},{"id":"c","depends_on":["b"],"files":["c"]}]}'
run "$T/cy.json"
expect_rc cycle 1
has cycle "$out" 'a -> c -> b -> a'
plan cy1.json '{"tasks":[{"id":"a","depends_on":["a"],"files":["a"]}]}'
run "$T/cy1.json"
expect_rc self-cycle 1
has self-cycle "$out" 'a -> a'
plan un.json '{"tasks":[{"id":"a","depends_on":["ghost"],"files":["a"]}]}'
run "$T/un.json"
expect_rc unknown-dep 1
has unknown-dep "$out" 'unknown_dependency'
has unknown-dep "$out" 'ghost'
plan du.json '{"tasks":[{"id":"a","files":["a"]},{"id":"a","files":["b"]}]}'
run "$T/du.json"
expect_rc dup-id 1
has dup-id "$out" 'duplicate_id'
plan nf.json '{"tasks":[{"id":"a"},{"id":"b","files":[]}]}'
run "$T/nf.json"
expect_rc no-files 1
has no-files "$out" 'a declares no files'
has no-files "$out" 'b declares no files'
plan ab.json '{"tasks":[{"id":"a","files":["/etc/passwd"]}]}'
run "$T/ab.json"
expect_rc absolute 1
has absolute "$out" 'absolute'
plan dd.json '{"tasks":[{"id":"a","files":["a/../../b"]}]}'
run "$T/dd.json"
expect_rc dotdot 1
has dotdot "$out" "'..'"
for broad in '**' '.' '/' './' '*' '**/*' './**'; do
  plan br.json "{\"tasks\":[{\"id\":\"a\",\"files\":[\"$broad\"]}]}"
  run "$T/br.json"
  expect_rc "broad($broad)" 1
done
# all problems reported at once
plan all.json '{"tasks":[{"id":"a","depends_on":["ghost"]},{"id":"a","files":["/x"]},{"id":"b","files":["q"]},{"id":"c","files":["q"]}]}'
run "$T/all.json"
expect_rc all-problems 1
has all-problems "$out" 'duplicate_id'
has all-problems "$out" 'unknown_dependency'
has all-problems "$out" 'file_conflict'
plan empty.json '{"tasks":[]}'
run "$T/empty.json"
expect_rc empty-plan 1

# --- glob overlap: pairs ----------------------------------------------------
# overlap: expect conflict (rc 1); disjoint: expect rc 0
pair() { # want-rc p1 p2
  plan pr.json "{\"tasks\":[{\"id\":\"p\",\"files\":[\"$2\"]},{\"id\":\"q\",\"files\":[\"$3\"]}]}"
  run "$T/pr.json"
  expect_rc "overlap($2 | $3)" "$1"
}
pair 1 'a/b/**' 'a/b/c.go'
pair 1 'a/*.md' 'a/x.md'
pair 1 'a/b/' 'a/b/c/d'
pair 1 'a/x*' 'a/xy.go'
pair 1 'a/**/x.go' 'a/b/c/x.go'
pair 1 'a/*b*' 'a/c*d'
pair 1 'a/{b,c}.go' 'a/b.go'
pair 1 'A/B.go' 'a/b.go'
pair 1 'a/b' 'a/b/c.go'
pair 1 'a/v1.2/' 'a/v1.2/x.go'
pair 0 'a/b.go' 'a/b.go.bak'
pair 0 'a/x*' 'a/y*'
pair 0 'docs/**' 'src/**'
pair 0 'a/*.md' 'a/*.go'
pair 0 'a/*.md' 'a/x.go'
pair 0 'a/b.go' 'a/b.go/c'
pair 0 'a/b/**' 'a/c/**'
pair 0 'src/**/*.go' 'src/a/b.md'
plan multi.json '{"tasks":[{"id":"p","files":["m/1.go","m/2.go"]},{"id":"q","files":["n/1.go","m/2.go"]}]}'
run "$T/multi.json"
expect_rc multi-file 1
has multi-file "$out" 'm/2.go'
plan may.json '{"tasks":[{"id":"p","files":["a/x*"]},{"id":"q","files":["a/xy.go"]}]}'
run "$T/may.json"
has may-overlap "$out" 'may overlap'

# --- --max-width ------------------------------------------------------------
plan w5.json '{"tasks":[{"id":"e","files":["e"]},{"id":"c","files":["c"]},{"id":"a","files":["a"]},{"id":"d","files":["d"]},{"id":"b","files":["b"]}]}'
run "$T/w5.json" --format json --max-width 2
has width-batches "$out" '"batches":[[["a","b"],["c","d"],["e"]]]'
run "$T/w5.json" --max-width 2
has width-text "$out" 'batch 1.1: a b'
has width-text "$out" 'batch 1.3: e'
run "$T/w5.json" --max-width 0
expect_rc width-zero 2

# --- determinism ------------------------------------------------------------
run "$T/d.json" --format json; o1="$out"
run "$T/d.json" --format json; o2="$out"
eq deterministic "$o1" "$o2"
plan d2.json '{"tasks":[{"id":"c","files":["c.go"],"depends_on":["a"]},{"id":"a","files":["a.go"]},{"id":"d","depends_on":["c","b"],"files":["d.go"]},{"id":"b","depends_on":["a"],"files":["b.go"]}]}'
run "$T/d2.json" --format json
eq shuffled-input "$out" "$o1"
run "$T/d.json"; t1="$out"
run "$T/d2.json"
eq shuffled-text "$out" "$t1"

# --- the real prod-spec format (YAML), embedded verbatim shapes --------------
cat >"$T/real.yaml" <<'EOF'
# change-plan.yaml
context: .prod/context/resolved-context.yaml
semantic_events:
- none
files:
- path: a.sh
  action: create
  zone: shell
tasks:
- id: T1
  kind: implement
  summary: A folded summary that continues
    on a second line, with a comma and a: colon.
  files: [a.sh, "dir with, comma/b.sh"]   # trailing comment
  context: []
  focus: one question?
  ambiguity: none
  tier: sonnet
  acceptance: []
  depends_on: []
- id: T2
  kind: implement
  summary: "quoted, with a # not-a-comment"
  files:
  - c.sh
  - d/**
  depends_on:
  - T1
  - T3
- { id: T3, kind: implement, summary: "flow item, with: punctuation", files: ["e.sh"], ambiguity: none, acceptance: [], depends_on: [] }
- id: T4
  kind: acceptance-author
  files: [f.sh]
  depends_on: [T2]
  delivery: |
    block scalar
    over lines
EOF
run "$T/real.yaml" --format json
expect_rc real-yaml 0
eq real-yaml "$out" '{"ok":true,"waves":[["T1","T3"],["T2"],["T4"]],"max_width":2,"critical_path":["T1","T2","T4"],"verify_first":["T1","T2","T3"],"ready":["T1","T3"]}'
# PyYAML-style: list items at the key's own indent, as `yaml.dump` writes them
printf 'tasks:\n- id: A\n  files:\n  - x.go\n  depends_on: []\n- id: B\n  files: [x.go]\n  depends_on: []\n' >"$T/py.yaml"
run "$T/py.yaml"
expect_rc pyyaml-dump-conflict 1
has pyyaml-dump-conflict "$out" 'A and B'
# the repo's own committed plans, when present (a missing file is reported, not skipped silently)
repo_root="$(cd "$HERE/../.." && pwd)"
real1="$repo_root/benchmarks/eval/corpus/prod-review/clean-03-token-bucket/fixture/.prod/context/change-plan.yaml"
if [ -f "$real1" ]; then
  run "$real1"
  expect_rc repo-plan 0
else
  printf 'NOTE repo plan fixture absent, embedded real-format cases cover the format\n'
fi
# unsupported YAML is refused, never guessed
printf 'tasks:\n- id: &x A\n  files: [a]\n' >"$T/anch.yaml"
run "$T/anch.yaml"
expect_rc anchor-refused 2
printf 'tasks:\n- id: A\n  files:\n    nested: map\n' >"$T/nest.yaml"
run "$T/nest.yaml"
expect_rc nested-refused 2
printf 'key: v\n' >"$T/nt.yaml"
run "$T/nt.yaml"
expect_rc no-tasks-section 2

# --- scale: 200-task random DAG, time bounded ---------------------------------
python3 -I -B - "$T/big.json" <<'PY'
import json, random, sys
r = random.Random(7)
tasks = []
for i in range(200):
    deps = sorted({"t%03d" % r.randrange(i) for _ in range(r.randrange(4))}) if i else []
    tasks.append({"id": "t%03d" % i, "depends_on": deps, "files": ["pkg%03d/f.go" % i]})
r.shuffle(tasks)
json.dump({"tasks": tasks}, open(sys.argv[1], "w"))
# malformed inputs
junk = {
    "empty": "", "brace": "{", "tasks-only": "tasks:\n", "list": "[]", "null": "null",
    "tasks-int": '{"tasks":5}', "task-int": '{"tasks":[1]}', "bin": "\x00\x01\x02",
    "deep": "[" * 200000, "badyaml": "tasks:\n  - id: [\n", "tab": "tasks:\n\t- id: a\n",
    "quote": 'tasks:\n- id: "a\n', "idnull": '{"tasks":[{"id":null}]}',
    "depstr": '{"tasks":[{"id":"a","files":["x"],"depends_on":"b"}]}',
    "filesint": '{"tasks":[{"id":"a","files":[1]}]}',
    "flowbad": "tasks:\n- { id: a, files: [x }\n",
}
for k, v in junk.items():
    open(sys.argv[1] + "." + k, "w").write(v)
PY
start=$SECONDS
run "$T/big.json" --format json
expect_rc big-dag 0
has big-dag "$out" '"ok":true'
[ $((SECONDS - start)) -le 3 ] && ok || bad "big-dag took more than 3 s"
for f in "$T"/big.json.*; do
  run "$f"
  case "$rc" in 1 | 2) ok ;; *) bad "malformed ${f##*.}: rc=$rc" ;; esac
  hasnt "malformed-${f##*.}-traceback" "$err$out" 'Traceback'
  nl=$(printf '%s' "$err" | grep -c '' || true)
  [ "$nl" -le 1 ] && ok || bad "malformed ${f##*.}: stderr is $nl lines"
done
run "$T/does-not-exist.json"
expect_rc missing-file 2
hasnt missing-file-traceback "$err" 'Traceback'
run
expect_rc no-args 2
run "$T/d.json" --format xml
expect_rc bad-format 2
mkdir "$T/adir"
run "$T/adir"
expect_rc directory-as-plan 2
hasnt directory-traceback "$err" 'Traceback'

printf 'plan-dag-selftest: PASS %d FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
