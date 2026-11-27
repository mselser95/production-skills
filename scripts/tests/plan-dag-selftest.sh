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
  out="$(<"$T/out")"
  err="$(<"$T/err")"
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
# a --landed set that is not dependency-closed is refused (was: ready ["a"], exit 0)
run "$T/d.json" --format json --landed b
expect_rc landed-b-only 2
has landed-b-only "$err" 'dependency'
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
pair 1 'a/b.go' 'a/b.go/c'
pair 0 'a/b/**' 'a/c/**'
pair 1 'src/**/*.go' 'src/a/b.md'
pair 0 'src/**/*.go' 'docs/a/b.md'
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

# ============================================================================
# Review round 1 (B1-B5, W1-W5): every reproduction, as a case. Most are queued
# with bq and run by ONE python process (flush below) through the tool's own
# cli(): same code path as the command line, without a process per case.
nq=0
bq() { # label want-rc needle file [args...]; needle is searched in stdout+stderr
  printf '%s\t%s\t%s\t' "$1" "$2" "$3" >>"$T/batch.tsv"
  printf '%q ' "${@:4}" >>"$T/batch.tsv"
  printf '\n' >>"$T/batch.tsv"
}
# pairx WANT P Q: WANT 1 = reported as file_conflict (not any other rc 1)
pairx() {
  nq=$((nq + 1))
  plan "px$nq.json" "{\"tasks\":[{\"id\":\"p\",\"files\":[\"$2\"]},{\"id\":\"q\",\"files\":[\"$3\"]}]}"
  if [ "$1" = 1 ]; then bq "x($2 | $3)" 1 file_conflict "$T/px$nq.json"; else bq "x($2 | $3)" 0 "" "$T/px$nq.json"; fi
}
# B1: a dotted last component is NOT a file: a proper path-prefix always overlaps
pairx 1 'foo.d' 'foo.d/x'
pairx 1 'a/v1.2' 'a/v1.2/x.go'
pairx 1 'prod-new/modules/db-postgres/db/conf.d' 'prod-new/modules/db-postgres/db/conf.d/x'
pairx 1 'node_modules/.bin' 'node_modules/.bin/x'
pairx 1 'a/b.d' 'a/b.d/c'
pairx 1 '.github' '.github/workflows/pr.yaml'
pairx 1 'docs/v1.0' 'docs/v1.0/intro.md'
pairx 1 'a/*.d' 'a/x.d/f'
pairx 0 'foo.d' 'foo.dx/x'
# B2: braces are expanded BEFORE the path is split (a '/' may sit inside them)
pairx 1 '{src/a,test}/x.go' 'src/a/x.go'
pairx 1 '{src/a,test}/x.go' 'test/x.go'
pairx 1 'a/{b/c,d}.go' 'a/b/c.go'
pairx 1 'a/{b,{c/d,e}}/x' 'a/c/d/x'
pairx 1 'a/{b,{c/d,e}}/x' 'a/e/x'
pairx 0 '{src/a,test}/x.go' 'src/b/x.go'
pairx 0 'a/{b,{c/d,e}}/x' 'a/c/x'
g='{a,b}'
plan br9.json "{\"tasks\":[{\"id\":\"p\",\"files\":[\"$g$g$g$g$g$g$g$g$g\"]}]}"
bq brace-cap 1 too_broad "$T/br9.json"
plan ub.json '{"tasks":[{"id":"p","files":["a/{b,c"]}]}'
bq brace-unbalanced-open 1 bad_path "$T/ub.json"
plan ub2.json '{"tasks":[{"id":"p","files":["a/b},c"]}]}'
bq brace-unbalanced-close 1 bad_path "$T/ub2.json"
plan ub3.json '{"tasks":[{"id":"p","files":["{/etc,x}/y"]}]}'
bq brace-hides-absolute 1 absolute "$T/ub3.json"
# a pair with more than 4096 expansion combinations is reported as overlapping, not computed
g8='{a,b}/{a,b}/{a,b}/{a,b}/{a,b}/{a,b}/{a,b}/{a,b}'
h8='{c,d}/{c,d}/{c,d}/{c,d}/{c,d}/{c,d}/{c,d}/{c,d}'
pairx 1 "$g8" "$h8"
# B3: duplicate keys are refused, not resolved
printf 'tasks:\n- id: A\n  files: [x]\ntasks:\n- id: B\n  files: [x]\n' >"$T/dt.yaml"
bq dup-tasks-key 2 'tasks' "$T/dt.yaml"
printf 'tasks:\n- id: A\n  files: [x]\n  files: [y]\n- id: B\n  files: [x]\n' >"$T/df.yaml"
bq dup-files-key 2 'duplicate key `files`' "$T/df.yaml"
bq dup-files-key-names-task 2 'task A' "$T/df.yaml"
printf 'tasks:\n- id: A\n  id: B\n  files: [x]\n' >"$T/di.yaml"
bq dup-id-key 2 'duplicate key `id`' "$T/di.yaml"
printf 'tasks:\n- id: A\n  files: [x]\n  depends_on: []\n  depends_on: [B]\n' >"$T/dd2.yaml"
bq dup-depends-key 2 'duplicate key `depends_on`' "$T/dd2.yaml"
printf 'tasks:\n- { id: A, files: [x], files: [y] }\n' >"$T/dm.yaml"
bq dup-flow-map-key 2 'duplicate key' "$T/dm.yaml"
printf 'tasks:\n- id: A\n  files: [x]\n  kind: a\n  kind: b\n' >"$T/dk.yaml"
bq dup-kind-key 2 'duplicate key `kind`' "$T/dk.yaml"
printf 'tasks:\n- id: A\n  files: [x]\n  estimate: 1\n  estimate: 2\n' >"$T/de.yaml"
bq dup-estimate-key 2 'duplicate key `estimate`' "$T/de.yaml"
plan dj.json '{"tasks":[{"id":"a","files":["x"],"files":["y"]}]}'
bq dup-json-key 2 'twice' "$T/dj.json"
# decoys inside a block scalar / multi-line quoted scalar / unread flow list never become fields
printf 'tasks:\n- id: A\n  summary: |\n    - id: FAKE\n    files: [evil]\n    depends_on: [zz]\n  files: [x]\n- id: B\n  files: [x]\n' >"$T/dec.yaml"
bq decoy-block-scalar 1 'A and B' "$T/dec.yaml"
printf 'tasks:\n- id: A\n  summary: |\n    - id: FAKE\n    files: [evil]\n  files: [x]\n- id: B\n  files: [evil]\n' >"$T/dec1.yaml"
bq decoy-block-scalar-not-a-field 0 'tasks=2' "$T/dec1.yaml"
printf 'tasks:\n- id: A\n  summary: "one\n  files: [evil]\n  x: y"\n' >"$T/decq.yaml"
bq decoy-multiline-quote 2 'quoted scalar' "$T/decq.yaml"
# (a multi-line flow value of an unread key is valid YAML: `files: [evil]` inside it is NOT A's field)
printf 'tasks:\n- id: A\n  ctx: [a,\n  files: [evil]]\n  files: [x]\n- id: B\n  files: [evil]\n' >"$T/decf.yaml"
bq decoy-multiline-flow-not-a-field 0 'tasks=2' "$T/decf.yaml"
# B4: an item is a plain or quoted STRING; map / nested list / flow / alias shapes are refused
b4() { # label file-body ; the second task owns Makefile so a misread would pass silently
  printf 'tasks:\n- id: A\n  files:\n%s\n- id: B\n  files: [Makefile]\n' "$2" >"$T/b4-$1.yaml"
  bq "b4-$1" 2 "" "$T/b4-$1.yaml"
}
b4 map-item '  - path: Makefile'
b4 nested-list '  - - Makefile'
b4 flow-map-item '  - {path: Makefile}'
b4 flow-list-item '  - [Makefile]'
b4 brace-glob-unquoted '  - {a,b}.go'
b4 alias-glob '  - *.go'
b4 anchor '  - &x Makefile'
b4 tag '  - !x Makefile'
b4 trailing-colon '  - Makefile:'
b4 empty-item '  -'
b4 deeper-item $'  - a\n    - Makefile'
b4 mixed-indent $'  - a\n   - b'
b4 block-scalar-item '  - |'
printf 'tasks:\n- id: A\n  files: [path: Makefile]\n- id: B\n  files: [Makefile]\n' >"$T/b4f.yaml"
bq b4-flow-list-mapping 2 quote "$T/b4f.yaml"
printf 'tasks:\n- id: A\n  files: [[Makefile]]\n' >"$T/b4g.yaml"
bq b4-flow-nested-list 2 "" "$T/b4g.yaml"
printf 'tasks:\n- id: A\n  files: [*.go]\n' >"$T/b4h.yaml"
bq b4-flow-alias 2 quote "$T/b4h.yaml"
printf 'tasks:\n- id: A\n  files: [{a,b}.go]\n' >"$T/b4i.yaml"
bq b4-flow-brace-unquoted 2 "" "$T/b4i.yaml"
printf 'tasks:\n- id: A\n  files: [a/?.go]\n' >"$T/b4j.yaml"
bq b4-flow-question-unquoted 2 "" "$T/b4j.yaml"
printf 'tasks:\n- id: A\n  depends_on: [path: B]\n  files: [a]\n' >"$T/b4k.yaml"
bq b4-depends-mapping 2 "" "$T/b4k.yaml"
printf 'tasks:\n- id: [A]\n  files: [a]\n' >"$T/b4l.yaml"
bq b4-id-list 2 "" "$T/b4l.yaml"
# the same shapes, QUOTED, are plain strings and a glob inside quotes is a glob
printf 'tasks:\n- id: A\n  files:\n  - "{a,b}.go"\n  - '"'"'*.md'"'"'\n  - "path: x"\n- id: B\n  files: ["a.go", "{c}"]\n' >"$T/q.yaml"
bq quoted-glob-conflict 1 'A and B' "$T/q.yaml"
# W1: unquoted scalars YAML types as null/bool/int/float/timestamp are refused ("quote it")
for ty in null '~' yes No on 1 0 1.0 1.5 0x10 007 1:30 2024-01-01 '<<' .inf; do
  printf 'tasks:\n- id: %s\n  files: [a]\n' "$ty" >"$T/ty-u.yaml"
  cp "$T/ty-u.yaml" "$T/ty-u$nq.yaml"
  printf 'tasks:\n- id: "%s"\n  files: [a]\n' "$ty" >"$T/ty-q$nq.yaml"
  bq "typed-id($ty)" 2 quote "$T/ty-u$nq.yaml"
  bq "quoted-id($ty)" 0 "" "$T/ty-q$nq.yaml"
  nq=$((nq + 1))
done
printf 'tasks:\n- id: A\n  files: [on]\n' >"$T/ty2.yaml"
bq typed-file-entry 2 quote "$T/ty2.yaml"
printf 'tasks:\n- id: A\n  files: [a]\n  depends_on: [1]\n' >"$T/ty3.yaml"
bq typed-depends-entry 2 quote "$T/ty3.yaml"
printf 'tasks:\n- id: A\n  files:\n  - 2024-01-01\n' >"$T/ty4.yaml"
bq typed-block-item 2 quote "$T/ty4.yaml"
printf 'tasks:\n- { id: 1, files: [a] }\n' >"$T/ty5.yaml"
bq typed-flow-map-id 2 quote "$T/ty5.yaml"
plan ji.json '{"tasks":[{"id":1,"files":["a"]}]}'
bq json-int-id 1 missing_id "$T/ji.json"
printf 'tasks:\n- id:\n  files: [a]\n' >"$T/idn.yaml"
bq empty-id-is-null 1 missing_id "$T/idn.yaml"
# W2: a plain scalar continuing on the next line is refused, never truncated
printf 'tasks:\n- id: A\n    B\n  files: [x]\n' >"$T/w2.yaml"
bq continuation-id 2 'ONE line' "$T/w2.yaml"
printf 'tasks:\n- id: A\n  files: [x]\n  depends_on: B\n    C\n' >"$T/w2b.yaml"
bq continuation-depends 2 'ONE line' "$T/w2b.yaml"
printf 'tasks:\n- id: A\n  files: "x\n    y"\n' >"$T/w2c.yaml"
bq multiline-quoted-files 2 'quoted scalar' "$T/w2c.yaml"
printf 'tasks:\n- id: A\n  files: [x,\n    y]\n' >"$T/w2d.yaml"
bq multiline-flow-list-ok 0 "" "$T/w2d.yaml"
printf 'tasks:\n- id: A\n  files: [x\n    y]\n' >"$T/w2e.yaml"
bq multiline-flow-item-split 2 'one line' "$T/w2e.yaml"
printf 'tasks:\n- id: A\n  files: |\n    x\n' >"$T/w2f.yaml"
bq block-scalar-files 2 'block scalar' "$T/w2f.yaml"
# W3: NFC and NFD spellings of one name overlap
printf '{"tasks":[{"id":"p","files":["\303\251.go"]},{"id":"q","files":["e\314\201.go"]}]}' >"$T/nfc.json"
bq nfc-vs-nfd 1 file_conflict "$T/nfc.json"
# B5: --landed must be dependency-closed, without duplicates or empty ids
plan ch.json '{"tasks":[{"id":"a","files":["m.go"]},{"id":"b","depends_on":["a"],"files":["b.go"]},{"id":"d","depends_on":["b"],"files":["m.go"]}]}'
bq landed-not-closed 2 'b but not its dependency a' "$T/ch.json" --landed b
bq landed-transitive-gap 2 'd but not its dependency b' "$T/ch.json" --landed d,a
bq landed-closed 0 '  d' "$T/ch.json" --landed a,b
bq landed-diamond-gap 2 'dependency' "$T/d.json" --format json --landed b,c
bq landed-duplicate 2 'more than once' "$T/d.json" --landed a,a
bq landed-empty-middle 2 'empty id' "$T/d.json" --landed a,,b
bq landed-trailing-comma 2 'empty id' "$T/d.json" --landed a,
bq landed-leading-comma 2 'empty id' "$T/d.json" --landed ,a
bq landed-empty-string 0 '"ready":["a"]' "$T/d.json" --format json --landed ""
# W5: hard limits
python3 -I -B - "$T" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"tasks": [{"id": "t%d" % i, "files": ["p%d/f" % i]} for i in range(1001)]}, open(d + "/n1001.json", "w"))
json.dump({"tasks": [{"id": "t%d" % i, "files": ["p%d/f" % i]} for i in range(1000)]}, open(d + "/n1000.json", "w"))
json.dump({"tasks": [{"id": "a", "files": ["p%d/f" % i for i in range(2001)]}]}, open(d + "/f2001.json", "w"))
PY
bq too-many-tasks 2 'plan too large' "$T/n1001.json"
bq limit-tasks-ok 0 'tasks=1000' "$T/n1000.json"
bq too-many-paths 2 'plan too large' "$T/f2001.json"
# W4: invalid YAML in a field the tool never reads is accepted WITHOUT --strict-yaml (stated in --help)
printf 'summary: bad: yaml: here\ntasks:\n- id: A\n  files: [x]\n' >"$T/inv.yaml"
bq invalid-yaml-elsewhere-accepted-without-strict 0 'tasks=1' "$T/inv.yaml"
bq help 0 'Validates ONLY' --help
bq help-names-strict 0 '--strict-yaml' --help

# flush the queue: ONE process, the tool's cli() per case
nb_out="$(python3 -I -B - "$PD" "$T/batch.tsv" 2>&1 <<'PY'
import contextlib, importlib.util, io, shlex, sys
spec = importlib.util.spec_from_file_location("pd", sys.argv[1])
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)
n = failed = 0
for line in open(sys.argv[2], encoding="utf-8").read().split("\n"):
    if not line:
        continue
    label, want, needle, rest = line.split("\t")
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = pd.cli(shlex.split(rest))
    except SystemExit as e:
        rc = e.code
    text = out.getvalue() + err.getvalue()
    n += 1
    problems = []
    if str(rc) != want:
        problems.append("rc=%s want %s" % (rc, want))
    if needle and needle not in text:
        problems.append("missing %r" % needle)
    if "Traceback" in text:
        problems.append("traceback")
    if problems:
        failed += 1
        print("FAIL %s: %s (%s)" % (label, "; ".join(problems), text[:160].replace("\n", " | ")))
print("BATCH %d %d" % (n, failed))
PY
)" || true
printf '%s\n' "$nb_out" | grep -v '^BATCH ' || true
batch_line="$(printf '%s\n' "$nb_out" | grep '^BATCH ' || true)"
if [ -z "$batch_line" ]; then
  bad "batch runner printed no BATCH line: ${nb_out:0:300}"
else
  set -- $batch_line
  pass=$((pass + $2 - $3))
  fail=$((fail + $3))
fi

# --- cases that need the real command line -------------------------------------
run --help
expect_rc help-cli 0
if grep -q 'WHAT IS VALIDATED, AND WHAT IS NOT' "$PD"; then ok; else bad "header lacks the validation-scope statement"; fi
printf 'tasks:\n- id: A\n  files: [x]\n  depends_on: []\n- id: B\n  files: [y]\n  depends_on: [A]\n' >"$T/sv.yaml"
start=$SECONDS
run "$T/n1000.json"
[ $((SECONDS - start)) -le 5 ] && ok || bad "1000 tasks took more than 5 s"
run "$T/n1001.json"
expect_rc too-many-tasks-cli 2
has too-many-tasks-cli "$err" 'plan too large'

# --- reference interpreter (PyYAML), used ONLY here ---------------------------
REF_PY="${PLAN_DAG_REF_PYTHON:-$HOME/.cache/production-skills-tools/venv/bin/python3}"
have_ref=0
if [ -x "$REF_PY" ] && "$REF_PY" -I -B -c 'import yaml' >/dev/null 2>&1; then have_ref=1; fi
sys_has_yaml=0
if python3 -I -B -c 'import yaml' >/dev/null 2>&1; then sys_has_yaml=1; fi

# --strict-yaml without PyYAML: refused, saying why (needs a python WITHOUT yaml)
if [ "$sys_has_yaml" = 0 ]; then
  run "$T/d.json" --strict-yaml
  expect_rc strict-without-pyyaml 2
  has strict-without-pyyaml "$err" 'PyYAML'
else
  printf 'NOTE system python3 has PyYAML; the strict-without-PyYAML case is skipped\n'
fi
# oracle: overlap against a concrete path universe (stdlib only)
rc=0
out="$(python3 -I -B - "$PD" 600 1 2>&1 <<'PY'
import importlib.util
import random
import re
import sys

tool, NPAIRS, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
spec = importlib.util.spec_from_file_location("pd", tool)
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)
R = random.Random(seed)

DIRS = ["a", "b", "c", "v1.2", "x.d", ".git", "ab", "ba.d"]
NAMES = DIRS + ["f.go", "a.go", "b.md", "makefile"]
U = {(n,) for n in NAMES}
U |= {(d, n) for d in DIRS for n in NAMES}
d3 = [(a, b, n) for a in DIRS for b in DIRS for n in NAMES]
d4 = [(a, b, c, n) for a in DIRS for b in DIRS for c in DIRS[:5] for n in NAMES[:9]]
U |= set(R.sample(d3, 120))
U |= set(R.sample(d4, 90))
UNIVERSE = sorted(U)


# ---- oracle (independent of the tool's code) -------------------------------
def expand(s):
    m = re.search(r"\{([^{}]*)\}", s)
    if not m:
        return [s]
    out = []
    for alt in m.group(1).split(","):
        out += expand(s[:m.start()] + alt + s[m.end():])
    return out


_RE = {}


def comp_re(g):
    if g not in _RE:
        _RE[g] = _comp_re(g)
    return _RE[g]


def _comp_re(g):
    out = []
    i = 0
    while i < len(g):
        c = g[i]
        if c == "*":
            out.append(".*")
        elif c == "?":
            out.append(".")
        elif c == "[":
            j = g.index("]", i)
            out.append(g[i:j + 1])
            i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out))


KIDS = {(): set()}
for _x in UNIVERSE:
    for _k in range(1, len(_x) + 1):
        KIDS.setdefault(_x[:_k - 1], set()).add(_x[_k - 1])
        KIDS.setdefault(_x[:_k], set())
MATCH = {}


def match_comp(g, name):
    if (g, name) not in MATCH:
        MATCH[(g, name)] = comp_re(g).fullmatch(name) is not None
    return MATCH[(g, name)]


def matched_nodes(p):
    """Trie nodes (path prefixes, at least one component) that pattern p names exactly."""
    out, seen, stack = set(), set(), [(0, ())]
    while stack:
        st = stack.pop()
        if st in seen:
            continue
        seen.add(st)
        pi, node = st
        if pi == len(p):
            if node:
                out.add(node)
            continue
        if p[pi] == "**":
            stack.append((pi + 1, node))
            for ch in KIDS[node]:
                stack.append((pi, node + (ch,)))
        else:
            for ch in KIDS[node]:
                if match_comp(p[pi], ch):
                    stack.append((pi + 1, node + (ch,)))
    return out


def covers_all(pattern):
    """Universe paths the pattern names, or lies above (a path may be a directory)."""
    nodes = set()
    for e in expand(pattern.lower()):
        comps = [c for c in e.split("/") if c not in ("", ".")]
        if comps:
            nodes |= matched_nodes(comps)
    return frozenset(x for x in UNIVERSE if any(x[:k] in nodes for k in range(1, len(x) + 1)))


# ---- seeded pattern grammar -------------------------------------------------
def comp():
    r = R.random()
    if r < 0.35:
        return R.choice(NAMES)
    return R.choice(["*", "?", "a*", "*.go", "*.d", "[ab]", "[ab]*", "{a,b}", "{a,v1.2}", "{a,b}.go",
                     "x.*", "**", "*d", "**", "{a/b,c}", "{a/x.d,b}", "{a,{b,c}}", "{a/{b,c},v1.2}",
                     "{,a}", "?.d", "*.*"])


def pattern():
    n = R.randrange(1, 4)
    p = "/".join(comp() for _ in range(n))
    if R.random() < 0.2:
        p += "/"
    return p


_COV = {}


def cover_set(pattern):
    if pattern not in _COV:
        _COV[pattern] = covers_all(pattern)
    return _COV[pattern]


pairs = tot = fn = over = noshare = skipped = 0
fns = []
for _ in range(NPAIRS):
    a, b = pattern(), pattern()
    ea, bad_a = pd.norm_path(a)
    eb, bad_b = pd.norm_path(b)
    if bad_a or bad_b:
        skipped += 1
        continue
    pairs += 1
    shared = bool(cover_set(a) & cover_set(b))
    tool = pd.pair_overlap(ea, eb)
    if shared and not tool:
        fn += 1
        fns.append((a, b))
    if not shared:
        noshare += 1
        if tool:
            over += 1
print("ORACLE universe=%d pairs=%d skipped=%d false_negatives=%d over_reports=%d/%d (%.1f%%)"
      % (len(UNIVERSE), pairs, skipped, fn, over, noshare, 100.0 * over / max(noshare, 1)))
for a, b in fns[:10]:
    print("FALSE NEGATIVE", repr(a), repr(b))
sys.exit(1 if fn else 0)
PY
)" || rc=$?
printf '%s\n' "$out" | head -n 12
expect_rc overlap-oracle 0
has overlap-oracle "$out" 'false_negatives=0'
if [ "$have_ref" = 1 ]; then
  runref() { rc=0; "$REF_PY" -I -B "$PD" "$@" >"$T/out" 2>"$T/err" || rc=$?; out="$(<"$T/out")"; err="$(<"$T/err")"; }
  runref "$T/d.json" --strict-yaml
  expect_rc strict-valid-json 0
  runref "$T/sv.yaml" --strict-yaml
  expect_rc strict-valid-yaml 0
  runref "$T/inv.yaml" --strict-yaml
  expect_rc strict-invalid-yaml-elsewhere 2
  has strict-invalid-yaml-elsewhere "$err" 'PyYAML cannot load'
  if [ -f "$real1" ]; then
    runref "$real1" --strict-yaml
    expect_rc strict-real-plan 0
  fi
  runref "$T/real.yaml" --strict-yaml
  expect_rc strict-refuses-invalid-summary-in-embedded-plan 2
  corpus_bad="$repo_root/benchmarks/eval/corpus/prod-review/py-seeded-01-invoice-tax/fixture/.prod/context/change-plan.yaml"
  if [ -f "$corpus_bad" ]; then
    runref "$corpus_bad"
    expect_rc corpus-invalid-yaml-accepted-without-strict 0
    runref "$corpus_bad" --strict-yaml
    expect_rc corpus-invalid-yaml-refused-with-strict 2
  fi
  # differential against PyYAML: real plans, seeded adversarial plans, a token matrix
  rc=0
  out="$("$REF_PY" -I -B - "$PD" "$repo_root" 600 1 2>&1 <<'PY'
import importlib.util
import os
import random
import sys

import yaml

tool, root, N, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
spec = importlib.util.spec_from_file_location("pd", tool)
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)
VIEW = ("id", "depends_on", "files")


def same(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return str(a) == str(b)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def compare(text, name):
    """-> equal | refused | yaml-invalid | MISMATCH ... | CRASH ..."""
    try:
        doc = yaml.safe_load(text)
    except Exception:
        return "yaml-invalid"
    try:
        raw = pd.parse_plan(text, "plan.yaml")
    except pd.ParseError:
        return "refused"
    except Exception as e:
        return "CRASH %s: %s" % (name, e.__class__.__name__)
    yt = doc.get("tasks") if isinstance(doc, dict) else None
    if not isinstance(yt, list) or len(yt) != len(raw):
        return "MISMATCH %s: task count/shape (tool %d)" % (name, len(raw))
    for n, (a, b) in enumerate(zip(raw, yt), 1):
        if not isinstance(b, dict):
            return "MISMATCH %s: task %d is not a mapping for PyYAML" % (name, n)
        for k in VIEW:
            if not same(a.get(k), b.get(k)):
                return "MISMATCH %s: task %d %s: tool %r yaml %r" % (name, n, k, a.get(k), b.get(k))
    return "equal"


tally = {}
bad = []
CUR = {"t": tally}


def record(text, name):
    r = compare(text, name)
    key = r.split(" ")[0]
    CUR["t"][key] = CUR["t"].get(key, 0) + 1
    if key in ("MISMATCH", "CRASH"):
        bad.append((r, text))
    return key


# ---- every real plan in the repo -------------------------------------------
real = []
for dp, dn, fn in os.walk(root):
    dn[:] = [d for d in dn if d not in (".git", ".wt", "node_modules")]
    for f in fn:
        if f.startswith("change-plan") and f.endswith(".yaml"):
            real.append(os.path.join(dp, f))
real.sort()
rt = {}
for p in real:
    with open(p, encoding="utf-8") as fh:
        r = compare(fh.read(), p)
    k = r.split(" ")[0]
    rt[k] = rt.get(k, 0) + 1
    if k in ("MISMATCH", "CRASH"):
        bad.append((r, p))

# ---- seeded adversarial plans ----------------------------------------------
R = random.Random(seed)
SAFE = ["T1", "a.go", "src/x.go", "dir/**", "Makefile", "docs/*.md", "a b", "x-y_z", "v1.2", "1a", "b/c.d"]
TRICKY = ["yes", "No", "null", "~", "1", "0x10", "1.5", "1:30", "2024-01-01", "<<", "a: b", "a:", "- x",
          "*.go", "*x", "&x", "!x", "{a,b}.go", "[ab].go", "a, b", "a#b", "a #b", "it's", '"q"', "?x",
          "x?y", "a\tb", "@x", "`x", "%x", "|", "key: [x]", "a:b", "  lead", "=", "on", "Off", "007",
          "1_000", ".5", "+1", "-", "-x", "", "a]b", "a[b", "{x", "x}", "1e3", "0b101", "a/{b/c,d}.go"]


def render(s, mode):
    if mode == "plain":
        return s
    if mode == "dq":
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return "'" + s.replace("'", "''") + "'"


def tok():
    s = R.choice(SAFE) if R.random() < 0.88 else R.choice(TRICKY)
    return render(s, R.choice(["plain", "plain", "dq", "sq"]))


def toks(n):
    return [tok() for _ in range(n)]


def sty():
    return R.choice([0] * 5 + [1] * 5 + [2, 2, 3, 4, 5]) if R.random() < 0.97 else 6


def listval(key, ind, style):
    items = toks(R.randrange(0, 4))
    if style == 0:
        s = "[" + ", ".join(items) + (", " if items and R.random() < 0.2 else "") + "]"
        return [" " * ind + "%s: %s%s" % (key, s, "  # c" if R.random() < 0.2 else "")]
    if style == 1:
        out = [" " * ind + key + ":"]
        extra = R.choice([0, 2, 4]) if R.random() < 0.9 else R.choice([0, 2])
        for it in items:
            out.append(" " * (ind + extra) + "- " + it + ("  # c" if R.random() < 0.15 else ""))
        if R.random() < 0.1 and items:
            out.insert(2, " " * (ind + extra + 2) + "- " + tok())
        return out
    if style == 2:
        out = [" " * ind + key + ": [" + (items[0] if items else "")]
        for it in items[1:]:
            out.append(" " * (ind + 2) + "," + it if R.random() < 0.1 else " " * (ind + 2) + it + ",")
        out.append(" " * (ind + R.choice([0, 2])) + "]")
        return out
    if style == 3:
        return [" " * ind + "%s: %s" % (key, tok())]
    if style == 4:
        return [" " * ind + key + ":"]
    if style == 5:
        return [" " * ind + "%s: %s" % (key, R.choice(["null", "~", "[]", "[ ]", "|"]))]
    return [" " * ind + key + ": [" + ", ".join(items) + "] trailing"]


def extras(ind):
    k = R.randrange(9)
    P = " " * ind
    if k == 0:
        return [P + "summary: |", P + "  decoy", P + "  - id: FAKE", P + "  files: [evil]", P + "  depends_on: [zz]"]
    if k == 1:
        return [P + 'summary: "text: with, punct # not comment"']
    if k == 2:
        return [P + "context:", P + "  files: [nested-evil]", P + "  id: NESTED", P + "  - id: LIST"]
    if k == 3:
        return [P + "notes: plain text", P + "  continues here", P + "  files: [x]"]
    if k == 4:
        return [P + "acceptance:", P + "- a: b", P + "- c: d"] if ind == 2 else [P + "acceptance: []"]
    if k == 5:
        return [P + 'summary: "line1', P + "  files: [evil]", P + '  x: y"']
    if k == 6:
        return [P + "tier: sonnet  # c", P + "# comment line"]
    if k == 7:
        return [P + "ctx: [a,", P + "  files: [evil]]"]
    return [P + "summary: >-", P + "  folded", P + "  id: X"]


def task_lines(i):
    ind = 2
    keys = {}
    keys["id"] = [" " * ind + "id: " + (tok() if R.random() < 0.15 else "T%d" % i)]
    if R.random() < 0.08:
        keys["id"] = [" " * ind + "id:", " " * (ind + 2) + "CONT"]
    if R.random() < 0.05:
        keys["id"] = [" " * ind + "id: |", " " * (ind + 2) + "BLK"]
    keys["files"] = listval("files", ind, sty()) if R.random() < 0.95 else []
    keys["depends_on"] = listval("depends_on", ind, sty()) if R.random() < 0.8 else []
    keys["kind"] = [" " * ind + "kind: implement"]
    for e in range(R.randrange(3)):
        keys["x%d" % e] = extras(ind)
    if R.random() < 0.06:
        keys["dup"] = listval("files", ind, R.randrange(3))
    if R.random() < 0.04:
        keys["dup2"] = [" " * ind + "id: T%d" % i]
    order = list(keys)
    R.shuffle(order)
    lines = []
    for k in order:
        lines.extend(keys[k])
    # first line carries the dash
    first = lines[0]
    if not first.startswith(" " * ind) or first.strip() == "":
        return lines
    lines[0] = "- " + first[ind:]
    return [l if j == 0 else l for j, l in enumerate(lines)]


def flow_task(i):
    f = ", ".join(toks(R.randrange(0, 3)))
    d = ", ".join(toks(R.randrange(0, 2)))
    idv = tok() if R.random() < 0.3 else "T%d" % i
    parts = ["id: " + idv, "files: [" + f + "]", "depends_on: [" + d + "]", "kind: implement"]
    if R.random() < 0.1:
        parts.append("id: dup")
    R.shuffle(parts)
    return ["- { " + ", ".join(parts) + " }"]


def plan_text():
    n = R.randrange(1, 5)
    head = []
    if R.random() < 0.5:
        head.append("---")
    head.append("context: .prod/x.yaml")
    if R.random() < 0.3:
        head.append("summary: top level text")
    if R.random() < 0.2:
        head.extend(["files:", "- path: a.sh", "  action: create"])
    body = ["tasks:"]
    for i in range(n):
        if R.random() < 0.2:
            body.extend(flow_task(i))
        else:
            t = task_lines(i)
            body.extend(t)
        if R.random() < 0.15:
            body.append("# interleaved comment")
        if R.random() < 0.1:
            body.append("")
    tail = []
    if R.random() < 0.3:
        tail.append("after: value")
    if R.random() < 0.15:
        tail.extend(["tasks:", "- id: LATE", "  files: [late]"])
    if R.random() < 0.1:
        tail.append("tasks: []")
    text = "\n".join(head + body + tail) + "\n"
    if R.random() < 0.15:
        text = text.replace("\n", "\r\n")
    return text


for n in range(N):
    record(plan_text(), "gen#%d" % n)
GEN = dict(tally)

FIXED = [
    "tasks:\n- id: T1\n  depends_on: [a b\n    \"a #b\",\n  ]\n  files: [x]\n",
    "tasks:\n- id: A\n  summary: \"line1\n  files: [evil]\n  x: y\"\n  files: [real]\n",
    "tasks:\n- id: A\n  summary: |\n    - id: FAKE\n    files: [evil]\n  files: [real]\n",
    "tasks:\n- id: A\n  ctx: [a,\n  files: [evil]]\n  files: [real]\n",
    "tasks:\n- id: A\n  files: [a]\n  files: [b]\n",
    "tasks:\n- id: A\n  files: [a]\ntasks:\n- id: B\n  files: [b]\n",
    "tasks:\n- id: A\n  files:\n  - path: Makefile\n",
    "tasks:\n- id: A\n  files:\n  - - Makefile\n",
    "tasks:\n- id: A\n  files: [path: Makefile]\n",
    "tasks:\n- id: A\n    B\n  files: [x]\n",
    "tasks:\n- id: A\n  files:\n  - a\n    - b\n",
    "tasks:\r\n- id: A # c\r\n  files: [x] # c\r\n  depends_on:\r\n",
    "tasks:\n- id: A\n  files: []\n  depends_on: ~\n",
    "tasks:\n- id: A\n  files:\n  depends_on: []\n- id: B\n  files: ['*.go', \"{a,b}.go\"]\n",
    "tasks:\n  - id: A\n    files:\n    - x\n    - y\n",
]
CUR["t"] = ft = {}
for i, t in enumerate(FIXED):
    record(t, "fixed#%d" % i)

# W1: the typed-scalar table, against PyYAML's own resolver
TABLE = ["", "null", "Null", "NULL", "~", "yes", "Yes", "YES", "no", "No", "true", "True", "FALSE", "on", "Off",
         "1", "-1", "+1", "0", "007", "08", "0x10", "0b101", "1_000", "1.0", "1.", "-.5", ".5", "1e3", "1.5e+3",
         ".inf", "-.inf", ".nan", "1:30", "190:20:30", "2024-01-01", "2024-1-1", "2001-12-14t21:59:43.10-05:00",
         "2001-12-14 21:59:43.10", "<<", "=", "A", "T1", "1a", "1.2.3", "v1.2", "src/x.go", "y", "n", "0o17",
         "nul", "~x", "a b", "a:b", "12:30", "1e+3", "0.", "00", "-0", "+.5", "0xg"]
table_bad = []
for sc in TABLE:
    try:
        typed = not isinstance(yaml.safe_load("v: " + sc)["v"], str)
    except Exception:
        typed = True
    if pd.yaml_typed(sc) != typed:
        table_bad.append(sc)
print("TYPED table=%d disagreements=%d %s" % (len(TABLE), len(table_bad), table_bad))

# W4: the strict-yaml view comparison itself
sy = [
    pd.strict_yaml_check("tasks:\n- id: A\n  files: [x]\n", [{"id": "A", "files": ["x"]}]) is None,
    pd.strict_yaml_check("tasks:\n- id: A\n  files: [x]\n", [{"id": "A", "files": ["y"]}]) is not None,
    pd.strict_yaml_check("tasks:\n- id: A\n  files: [x]\n", [{"id": "B", "files": ["x"]}]) is not None,
    pd.strict_yaml_check("tasks:\n- id: A\n  depends_on: [q]\n", [{"id": "A", "depends_on": []}]) is not None,
    pd.strict_yaml_check("tasks:\n- id: A\n", [{"id": "A"}, {"id": "B"}]) is not None,
    pd.strict_yaml_check("tasks: [\n", []) is not None,
]
print("STRICT checks=%d wrong=%d" % (len(sy), sy.count(False)))

# systematic matrix: every token, every quoting, every position
POS = [
    "tasks:\n- id: %s\n  files: [a]\n",
    "tasks:\n- id: A\n  files: [%s]\n",
    "tasks:\n- id: A\n  files:\n  - %s\n",
    "tasks:\n- id: A\n  files: [a]\n  depends_on: [%s]\n",
    "tasks:\n- id: A\n  files: [a]\n  depends_on:\n    - %s\n",
    "tasks:\n- { id: A, files: [%s] }\n",
    "tasks:\n- { id: %s, files: [a] }\n",
    "tasks:\n- id: A\n  files: %s\n",
    "tasks:\n- id: A\n  files: [a]\n  depends_on: %s\n",
    "tasks:\n- id: A\n  files: [a, %s, b]\n",
]
CUR["t"] = mt = {}
for t in SAFE + TRICKY:
    for mode in ("plain", "dq", "sq"):
        for pos in POS:
            record(pos % render(t, mode), "matrix %r %s %r" % (t, mode, pos))
print("MATRIX", " ".join("%s=%d" % kv for kv in sorted(mt.items())))
print("FIXED", " ".join("%s=%d" % kv for kv in sorted(ft.items())))

print("REAL", " ".join("%s=%d" % kv for kv in sorted(rt.items())), "files=%d" % len(real))
print("GEN", " ".join("%s=%d" % kv for kv in sorted(GEN.items())), "plans=%d" % N)
for r, t in bad[:int(os.environ.get("SHOW", "3"))]:
    print("----", r)
    print(t)
print("DIFF mismatches=%d typed_disagreements=%d strict_wrong=%d real_equal=%d gen_equal=%d"
      % (len(bad), len(table_bad), sy.count(False), rt.get("equal", 0), GEN.get("equal", 0)))
sys.exit(1 if (bad or table_bad or sy.count(False) or GEN.get("equal", 0) < 60) else 0)
PY
)" || rc=$?
  printf '%s\n' "$out" | head -n 14
  expect_rc differential-vs-pyyaml 0
  has differential-vs-pyyaml "$out" 'DIFF mismatches=0 typed_disagreements=0 strict_wrong=0'
else
  printf 'SKIP differential vs PyYAML and --strict-yaml cases: reference interpreter %s has no PyYAML (set PLAN_DAG_REF_PYTHON)\n' "$REF_PY"
fi

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

printf 'plan-dag-selftest: %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
