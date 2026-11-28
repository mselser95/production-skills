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
skipped=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# PyYAML probe. CI runs the tool as `python3 -I -B`, so that is the probe that counts.
# Importable plainly but not under -I (PyYAML only in the user site) means the tool cannot
# read YAML the way CI runs it: that is a FAIL, never a quiet skip of 25 cases.
HAVE_YAML=0
YAML_PLAIN=0
if python3 -I -B -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=1; fi
if python3 -B -c 'import yaml' >/dev/null 2>&1; then YAML_PLAIN=1; fi
if [ "$YAML_PLAIN" = 1 ] && [ "$HAVE_YAML" = 0 ]; then
  bad "PyYAML is importable by python3 but not by python3 -I: install it into the interpreter's own site-packages"
fi
if [ "${PLAN_DAG_ST_PROBE_ONLY:-0}" = 1 ]; then # meta-case mode: report the probe, run nothing else
  printf 'probe: have_yaml=%s plain=%s fail=%s\n' "$HAVE_YAML" "$YAML_PLAIN" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi
skip() { skipped=$((skipped + 1)); printf 'SKIPPED %s: PyYAML not importable\n' "$1"; }
# yaml_only LABEL: true when YAML cases can run, else count a skip
yaml_only() { if [ "$HAVE_YAML" = 1 ]; then return 0; fi; skip "$1"; return 1; }

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
  plan br.json "{\"tasks\":[{\"id\":\"a\",\"files\":[\"$broad\"]},{\"id\":\"b\",\"files\":[\"z/q\"]}]}"
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


# --- --landed closure (round-1 B5), real command line ----------------------------
plan ch.json '{"tasks":[{"id":"a","files":["m.go"]},{"id":"b","depends_on":["a"],"files":["b.go"]},{"id":"d","depends_on":["b"],"files":["m.go"]}]}'
run "$T/ch.json" --landed b
expect_rc landed-not-closed 2
has landed-not-closed "$err" 'b but not its dependency a'
run "$T/ch.json" --landed d,a
has landed-transitive-gap "$err" 'd but not its dependency b'
run "$T/ch.json" --landed a,b
expect_rc landed-closed 0
for bad_landed in 'a,a' 'a,,b' 'a,' ',a'; do
  run "$T/d.json" --landed "$bad_landed"
  expect_rc "landed($bad_landed)" 2
done
run "$T/d.json" --format json --landed ""
has landed-empty-string "$out" '"ready":["a"]'

# --- round-1 blockers B1-B4 and the no-PyYAML contract, real command line, python3 -I -B
plan b1.json '{"tasks":[{"id":"p","files":["foo.d"]},{"id":"q","files":["foo.d/x"]}]}'
run "$T/b1.json"
expect_rc B1-dotted-dir-vs-child 1
has B1-dotted-dir-vs-child "$out" 'file_conflict'
plan b2.json '{"tasks":[{"id":"p","files":["a/{b/c,d}/e"]},{"id":"q","files":["a/b/c/e"]}]}'
run "$T/b2.json"
expect_rc B2-brace-with-slash 1
has B2-brace-with-slash "$out" 'file_conflict'
plan b2b.json '{"tasks":[{"id":"p","files":["a/{b/c,d}/e"]},{"id":"q","files":["a/d/f"]}]}'
run "$T/b2b.json"
expect_rc B2-brace-disjoint 0
plan b3.json '{"tasks":[{"id":"a","files":["x"],"files":["y"]}]}'
run "$T/b3.json"
expect_rc B3-duplicate-key-json 2
has B3-duplicate-key-json "$err" 'appears twice'
if yaml_only B3-B4-yaml-command-line; then
  plan b3.yaml $'tasks:\n- id: a\n  files: [x]\n  files: [y]\n'
  run "$T/b3.yaml"
  expect_rc B3-duplicate-key-yaml 2
  plan b4a.yaml $'tasks:\n- id: a\n  files:\n  - path: x\n'
  run "$T/b4a.yaml"
  expect_rc B4-mapping-item 1
  has B4-mapping-item "$out" 'bad_field'
  plan b4b.yaml $'tasks:\n- id: a\n  files:\n  - - x\n'
  run "$T/b4b.yaml"
  expect_rc B4-nested-list-item 1
  plan b4c.yaml $'tasks:\n- id: a\n  files:\n  - *.go\n'
  run "$T/b4c.yaml"
  expect_rc B4-unquoted-glob-alias 2
  plan b4d.yaml $'tasks:\n- id: a\n  files: [{k: v}]\n'
  run "$T/b4d.yaml"
  expect_rc B4-flow-map-item 1
  plan ok.yaml $'tasks:\n- id: A\n  files: [x]\n  estimate: 2\n- id: B\n  files: [y]\n  depends_on: [A]\n  estimate: 3\n'
  run "$T/ok.yaml"
  expect_rc yaml-ok 0
  has yaml-ok "$out" 'critical path by estimate (5): A -> B'
  run "$T/ok.yaml" --strict-yaml
  expect_rc strict-yaml-noop 0
fi
# no PyYAML (import blocked in this process, so it holds on any machine): YAML is exit 2, JSON works
noyaml() {
  rc=0
  python3 -I -B -c 'import runpy, sys; sys.modules["yaml"] = None; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' \
    "$PD" "$@" >"$T/out" 2>"$T/err" || rc=$?
  out="$(<"$T/out")"
  err="$(<"$T/err")"
}
printf 'tasks:\n- id: A\n  files: [x]\n' >"$T/nov.yaml"
noyaml "$T/nov.yaml"
expect_rc no-pyyaml-yaml-plan 2
eq no-pyyaml-yaml-plan "$err" 'plan-dag: cannot parse plan: PyYAML is required to read a YAML plan (pip install PyYAML), or pass the plan as JSON'
noyaml "$T/d.json"
expect_rc no-pyyaml-json-plan 0
has no-pyyaml-json-plan "$out" 'tasks=4'
# meta-case: a stub python3 on PATH that imports yaml plainly but not under -I must make the
# suite FAIL; one that imports it nowhere is a genuine absence and stays exit 0
REAL_PY="$(command -v python3)"
mkdir "$T/stub-user" "$T/stub-none"
for kind in user none; do
  cat >"$T/stub-$kind/python3" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"import yaml"*)
    if [ "$kind" = none ]; then exit 1; fi
    for a in "\$@"; do if [ "\$a" = -I ]; then exit 1; fi; done
    exit 0 ;;
esac
exec "$REAL_PY" "\$@"
STUB
  chmod +x "$T/stub-$kind/python3"
done
mrc=0
mout="$(PATH="$T/stub-user:$PATH" PLAN_DAG_ST_PROBE_ONLY=1 bash "${BASH_SOURCE[0]}" 2>&1)" || mrc=$?
[ "$mrc" -ne 0 ] && ok || bad "probe-meta: plain-importable but not under -I must fail the suite (rc=$mrc)"
has probe-meta-message "$mout" "importable by python3 but not by python3 -I"
mrc=0
mout="$(PATH="$T/stub-none:$PATH" PLAN_DAG_ST_PROBE_ONLY=1 bash "${BASH_SOURCE[0]}" 2>&1)" || mrc=$?
eq probe-meta-absent-is-skip "$mrc:$mout" "0:probe: have_yaml=0 plain=0 fail=0"
run --help
expect_rc help-cli 0
has help-literal-alphabet "$out" 'A-Z a-z 0-9 . _ - + @ = , %'
has help-ascii-lower "$out" 'ASCII lower-casing'
has help-overlap-rule "$out" 'src/*.go and'
has help-overlap-advice "$out" 'list files explicitly or add depends_on'

# --- in-process cases, the soundness oracle and its canaries (one python process)
ROOT="$(cd "$HERE/../.." && pwd)"
cat >"$T/h.py" <<'PY'
import contextlib
import fnmatch
import importlib.util
import io
import json
import os
import random
import re
import sys
import time
import unicodedata

tool, tmp, root = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pd", tool)
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)
try:
    import yaml
except ImportError:
    yaml = None

N = {"ok": 0, "fail": 0, "skip": 0}


def check(label, cond, detail=""):
    if cond:
        N["ok"] += 1
    else:
        N["fail"] += 1
        print("FAIL %s %s" % (label, str(detail)[:300]))


def skip(label):
    N["skip"] += 1
    print("SKIPPED %s: PyYAML not importable" % label)


def cli(argv):
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        try:
            rc = pd.cli(argv)
        except SystemExit as x:
            rc = x.code
    return rc, o.getvalue(), e.getvalue()


seq = [0]


def plan(text, ext="json"):
    seq[0] += 1
    p = os.path.join(tmp, "h%d.%s" % (seq[0], ext))
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    return p


def jplan(*tasks):
    return plan(json.dumps({"tasks": list(tasks)}))


def case(label, text, rc, needle="", ext="json"):
    r, o, e = cli([plan(text, ext)])
    check(label, r == rc and needle in o + e, "rc=%s %s%s" % (r, o[:150], e[:150]))


def ycase(label, text, rc, needle=""):
    if yaml is None:
        skip(label)
    else:
        case(label, text, rc, needle, "yaml")


def pair(want, p, q):
    """want: 'ok' (rc 0) or a code that must be named (rc 1)."""
    r, o, e = cli([jplan({"id": "p", "files": [p]}, {"id": "q", "files": [q]})])
    lab = "pair(%r | %r)" % (p, q)
    if want == "ok":
        check(lab + " disjoint", r == 0, o)
    else:
        check(lab + " " + want, r == 1 and want in o, "rc=%s %s" % (r, o[:200]))


# ---- round-2 false negatives (each used to run together) and the usual shapes
for p, q in [("src/[ab].go", "src/[a-c].go"), ("src/[ab].go", "src/[ax].go"), ("a/[ab]x", "a/*bx"),
             ("pkg/v[0-9].go", "pkg/*1.go"), ("src/[!A].go", "src/a.go"), ("x/?.go", "x/ß.go"),
             ("x/?.go", "x/İ.go"), ("src/a[A-z]b", "src/a_b"), ("x/??", "x/é"),
             ("a/b/**", "a/b/c.go"), ("a/*.md", "a/x.md"), ("a/b/", "a/b/c/d"), ("a/**/x.go", "a/b/c/x.go"),
             ("a/{b,c}.go", "a/b.go"), ("A/B.go", "a/b.go"), ("a/b", "a/b/c.go"), ("foo.d", "foo.d/x"),
             ("a/v1.2", "a/v1.2/x.go"), ("node_modules/.bin", "node_modules/.bin/x"),
             (".github", ".github/workflows/pr.yaml"), ("a/*.d", "a/x.d/f"), ("src/*.go", "src/*.md"),
             ("a/x*", "a/y*"), ("a/*.md", "a/x.go"), ("src/**/*.go", "src/a/b.md"),
             ("a/é.go", "a/é.go"), ("a/b.go", "a/b.go/c"), ("{a/b,c}/x", "c/x/y"),
             ("a//b", "a/./b"), ("./a/b", "a/b/"), ("a/b", "a/b")]:
    pair("file_conflict", p, q)
for p, q in [("a/b.go", "a/b.go.bak"), ("docs/**", "src/**"), ("a/b/**", "a/c/**"),
             ("src/**/*.go", "docs/a/b.md"), ("a/b/c.go", "A/B/D.go"), ("{a/b,c}/x", "a/b/y"),
             ("docs/*.md", "src/*.go"), ("m/1.go", "m/2.go"), ("m/{1,2}.go", "m/3.go")]:
    pair("ok", p, q)
for p in ["**", "*.go", "**/x", "{*,a}/x", "[ab]/x", "./*", ".", "./"]:
    pair("too_broad", p, "z/q")
pair("bad_path", "m/{001..003}.sql", "m/002.sql")
for p in ["/etc/x", "~/x", "C:x", "a\\b", "a/../b", "a/{..,b}", "{a", "a}", "{}", "a/{b,c", "{1..3}",
          "a/{}/b", "a\u0007b", "/".join("d%d" % i for i in range(33))]:
    pair("bad_path", p, "z/q")
pair("too_broad", "x/{%s}" % ",".join(str(i) for i in range(257)), "z/q")
pair("ok", "x/{%s}" % ",".join(str(i) for i in range(256)), "z/q")
r, o, e = cli([jplan({"id": "a", "files": ["a\u0000b"]}, {"id": "b", "files": ["z/q"]})])
check("nul-in-path", r == 1 and "bad_path" in o, o)
r, o, e = cli([jplan({"id": "a", "files": ["**/*.go"]})])
check("single-task-wildcard-ok", r == 0, o + e)
r, o, e = cli([jplan({"id": "a", "files": ["/".join("d%d" % i for i in range(32))]})])
check("32-components-ok", r == 0, o + e)

# ---- round-3: a component is literal only if pure ASCII from the safe alphabet
for p, q in [("src/\u1fb7.go", "src/\u1fbc\u0342.go"),  # canonically caseless-equal: one file on APFS
             ("src/\u00e9.go", "src/e\u0301.go"),           # NFC vs NFD
             ("src/\u00e9.go", "src/a.go"),                  # non-literal stops the prefix at `src`
             ("Src/A.go", "src/a.go"), ("src/a.", "src/a"), ("src/a..", "src/a"),
             ("src/+(a|b).go", "src/a.go"), ("src/@(a|b).go", "src/a.go"), ("src/!(x).go", "src/a.go"),
             ("src/$V.go", "src/a.go"), ("src/a b.go", "src/a.go"), ("src/`x`.go", "src/a.go"),
             ("src/\u212a.go", "src/k.go"), ("src/\u00df.go", "src/ss.go")]:
    pair("file_conflict", p, q)
# NTFS 8.3 short names (ABCDEF~1.GO) may alias another file: a component with ~ is never literal
pair("file_conflict", "src/abcdef~1.go", "src/abcdefghij.go")
for p, q in [("src/a.go", "src/b.go"), ("src/a-b_c+d@e=f,g%hi.go", "src/a-b_c+d@e=f,g%hj.go"),
             ("a/\u00e9.go", "b/\u00e9.go")]:
    pair("ok", p, q)
pair("too_broad", "\u00e9/x.go", "z/q")
pair("too_broad", "\u00e9", "z/q")
pair("too_broad", "$V/x.go", "z/q")
r, o, e = cli([jplan({"id": "a", "files": ["\u00e9/x.go"]})])
check("single-task-non-ascii-first-ok", r == 0, o + e)

# ---- round-3 warnings
# 1: the path limit is enforced while expanding (was: after expanding everything, 85 s)
wide = ",".join("a%d" % k for k in range(256))
t0 = time.time()
r, o, e = cli([jplan(*[{"id": "t%d" % i, "files": ["x%d_%d/{%s}" % (i, j, wide) for j in range(40)]}
                       for i in range(1000)])])
dt = time.time() - t0
check("limit-in-loop-fast", r == 2 and "plan too large" in e and dt < 10, "rc=%s %.1fs %s" % (r, dt, e[:100]))
print("INFO limit-in-loop: %.2fs" % dt)
# 2: every error class is capped, text and JSON
for code, mk in (("bad_path", lambda i: {"id": "t%d" % i, "files": ["/a"] * 40}),
                 ("too_broad", lambda i: {"id": "t%d" % i, "files": ["*.go"]}),
                 ("bad_field", lambda i: {"id": "t%d" % i, "files": "x"}),
                 ("no_files", lambda i: {"id": "t%d" % i})):
    n = 40000 if code == "bad_path" else 1000
    tasks = [mk(i) for i in range(1000)]
    r, o, e = cli([jplan(*tasks)])
    total = 40000 if code == "bad_path" else 1000
    check("cap-text-" + code, r == 1 and o.count("ERROR " + code) == 50 and o.count("\n") == 51
          and "... and %d more %s" % (total - 50, code) in o and len(o) < 20000, "%d lines %d bytes" % (o.count("\n"), len(o)))
    r, o, e = cli([jplan(*tasks), "--format", "json"])
    d = json.loads(o)
    check("cap-json-" + code, len(d["errors"]) == 50 and d["more"] == {code: total - 50} and len(o) < 20000, o[-120:])
    print("INFO cap %s: %d entries -> text %d lines" % (code, total, 51))
# 4: a lone surrogate is a bad_field, not an internal error; output never raises
for label, doc in (("id", '{"tasks":[{"id":"\\ud800","files":["x"]}]}'),
                   ("file", '{"tasks":[{"id":"a","files":["x\\udc80"]}]}'),
                   ("depends", '{"tasks":[{"id":"a","files":["x"],"depends_on":["\\ud800"]}]}')):
    r, o, e = cli([plan(doc)])
    check("surrogate-" + label, r == 1 and "bad_field" in o and o.count("\n") == 1 and "internal error" not in e, "rc=%s %s%s" % (r, o, e))
raw = io.BytesIO()
ascii_out = io.TextIOWrapper(raw, encoding="ascii", errors="strict")
with contextlib.redirect_stdout(ascii_out), contextlib.redirect_stderr(io.StringIO()):
    r = pd.cli([jplan({"id": "p", "files": ["s/\u00e9"]}, {"id": "q", "files": ["s/\u00e9"]})])
ascii_out.flush()
check("output-never-raises", r == 1 and b"\\xe9" in raw.getvalue(), "rc=%s %r" % (r, raw.getvalue()[:80]))
# 5: ids stay distinct but a plan whose ids differ only by case / normalisation is refused
for a, b in (("A", "a"), ("\u00e9", "e\u0301"), ("Task-1", "task-1")):
    r, o, e = cli([jplan({"id": a, "files": ["x"]}, {"id": b, "files": ["y"]})])
    check("id-clash-%r" % a, r == 1 and "ids differ only by case or normalisation" in o and o.count("\n") == 1, o)
r, o, e = cli([jplan({"id": "a", "files": ["x"]}, {"id": "b", "files": ["y"]}, {"id": "ab", "files": ["z"]})])
check("distinct-ids-ok", r == 0, o + e)

# ---- loading: types, duplicate keys, estimates, documents
case("json-dup-top", '{"tasks":[],"tasks":[]}', 2, "appears twice")
case("json-dup-task", '{"tasks":[{"id":"a","id":"b","files":["x"]}]}', 2, "appears twice")
case("json-dup-nested", '{"tasks":[{"id":"a","files":["x"],"m":{"k":1,"k":2}}]}', 2, "appears twice")
case("json-nan-estimate", '{"tasks":[{"id":"a","files":["x"],"estimate":NaN}]}', 2, "not allowed")
case("json-id-null", '{"tasks":[{"id":null,"files":["x"]}]}', 1, "quote it")
case("json-id-int", '{"tasks":[{"id":1,"files":["x"]}]}', 1, "bad_field")
case("json-depends-scalar", '{"tasks":[{"id":"a","files":["x"],"depends_on":"b"}]}', 1, "depends_on must be a list")
case("json-files-scalar", '{"tasks":[{"id":"a","files":"x"}]}', 1, "files must be a list")
case("json-estimate-string", '{"tasks":[{"id":"a","files":["x"],"estimate":"3"}]}', 1, "estimate must be a number")
case("json-estimate-negative", '{"tasks":[{"id":"a","files":["x"],"estimate":-1}]}', 1, "estimate must be a number")
case("json-estimate-bool", '{"tasks":[{"id":"a","files":["x"],"estimate":true}]}', 1, "estimate must be a number")
est = ('{"tasks":[{"id":"a","files":["x"],"estimate":3},{"id":"b","files":["y"],"depends_on":["a"],"estimate":4.5},'
       '{"id":"c","files":["z"],"estimate":1}]}')
case("json-estimate-path", est, 0, "critical path by estimate (7.5): a -> b")
ycase("yaml-estimate-path", "tasks:\n- id: a\n  files: [x]\n  estimate: 3\n- id: b\n  files: [y]\n"
      "  depends_on: [a]\n  estimate: 4.5\n- id: c\n  files: [z]\n  estimate: 1\n", 0,
      "critical path by estimate (7.5): a -> b")
ycase("yaml-estimate-string", "tasks:\n- id: a\n  files: [x]\n  estimate: '3'\n", 1, "estimate must be a number")
ycase("yaml-dup-top", "tasks:\n- id: a\n  files: [x]\ntasks:\n- id: b\n  files: [y]\n", 2, "appears twice")
ycase("yaml-dup-task", "tasks:\n- id: a\n  id: b\n  files: [x]\n", 2, "appears twice")
ycase("yaml-dup-nested", "tasks:\n- id: a\n  files: [x]\n  meta:\n    k: 1\n    k: 2\n", 2, "appears twice")
ycase("yaml-two-documents", "tasks:\n- id: a\n  files: [x]\n---\ntasks:\n- id: b\n  files: [y]\n", 2, "one document")
ycase("yaml-invalid-elsewhere", "note: [\ntasks:\n- id: a\n  files: [x]\n", 2, "not valid YAML")
for v in ("1", "null", "yes", "2024-01-01", "1.5", "~"):
    ycase("yaml-id-%s" % v, "tasks:\n- id: %s\n  files: [x]\n" % v, 1, "quote it")
ycase("yaml-id-quoted", "tasks:\n- id: '1'\n  files: [x]\n", 0, "tasks=1")
ycase("yaml-depends-scalar", "tasks:\n- id: a\n  files: [x]\n  depends_on: b\n", 1, "depends_on must be a list")
ycase("yaml-files-map", "tasks:\n- id: a\n  files:\n  - path: x\n", 1, "files must be a list")
ycase("yaml-nested-files-ignored", "tasks:\n- id: a\n  files: [x]\n  extra:\n    files: [y]\n  other: 1\n", 0, "tasks=1")
ycase("yaml-no-tasks-list", "tasks: 5\n", 2, "`tasks` list")
ycase("yaml-top-list", "- a\n- b\n", 2, "`tasks` list")

# ---- the three round-2 YAML mis-reads: the tool's view is PyYAML's view
def view(tasks):
    return [(t.get("id"), t.get("depends_on"), t.get("files")) if isinstance(t, dict) else None for t in tasks]


def differs(text):
    return view(pd.load_plan("p.yaml", text)) != view(yaml.safe_load(text)["tasks"])


S1 = "tasks:\n- id: a 'b #c\n  files: [x]\n"
S2 = "tasks:\n- {id:a, files: [x]}\n"
S3 = 'note: "first\ntasks:\n- id: z\n  files: [q]\n"\n'
if yaml is None:
    for n in ("view-trailing-comment", "view-flow-id-colon", "view-scalar-tasks", "differential-canary"):
        skip(n)
else:
    check("view-trailing-comment", not differs(S1) and view(pd.load_plan("p.yaml", S1))[0][0] == "a 'b")
    check("view-flow-id-colon", not differs(S2) and view(pd.load_plan("p.yaml", S2))[0][0] is None)
    r, o, e = cli([plan(S2, "yaml")])
    check("flow-id-colon-refused", r == 1 and "missing_id" in o, o + e)
    r, o, e = cli([plan(S3, "yaml")])
    check("view-scalar-tasks", r == 2 and yaml.safe_load(S3).get("tasks") is None, o + e)
    real_load = pd.load_plan
    pd.load_plan = lambda path, text=None: [{k: v for k, v in t.items() if k != "files"}
                                             for t in real_load(path, text)]
    try:
        caught = differs(S1)
    finally:
        pd.load_plan = real_load
    check("differential-canary", caught is True, "a loader that drops `files` was not noticed")

# ---- no PyYAML: YAML is exit 2 with one line, JSON still works
saved = sys.modules.get("yaml", "absent")
sys.modules["yaml"] = None
try:
    r, o, e = cli([plan("tasks:\n- id: a\n  files: [x]\n", "yaml")])
    check("no-pyyaml-yaml", r == 2 and e.strip() == "plan-dag: cannot parse plan: " + pd.NO_YAML
          and e.count("\n") == 1, "rc=%s %r" % (r, e))
    r, o, e = cli([jplan({"id": "a", "files": ["x"]})])
    check("no-pyyaml-json", r == 0 and "tasks=1" in o, o + e)
finally:
    if saved == "absent":
        del sys.modules["yaml"]
    else:
        sys.modules["yaml"] = saved

# ---- output cap and the 32-component entry
many = [{"id": "t%03d" % i, "files": ["shared/x"]} for i in range(300)]
r, o, e = cli([jplan(*many)])
check("conflict-cap-text", r == 1 and o.count("ERROR file_conflict") == 50
      and "... and %d more file_conflict" % (300 * 299 // 2 - 50) in o, o[-200:])
r, o, e = cli([jplan(*many), "--format", "json"])
d = json.loads(o)
check("conflict-cap-json", len(d["errors"]) == 50 and d["more_file_conflicts"] == 300 * 299 // 2 - 50, o[:100])

# ---- time: a quadratic blow-up must show
def timed(label, tasks, bound=30):
    p = jplan(*tasks)
    t0 = time.time()
    r, o, e = cli([p])
    dt = time.time() - t0
    check(label, r == 0 and dt < bound, "rc=%s %.1fs %s" % (r, dt, o[:100]))
    print("INFO %s: %.2fs" % (label, dt))


def comps(i, tail):
    return "/".join(["t%d" % i] + ["d%d" % k for k in range(29)] + [tail])


timed("stress-1000x2x31-components",
      [{"id": "t%d" % i, "files": [comps(i, "a"), comps(i, "b")]} for i in range(1000)])
timed("stress-1000-one-top-dir",
      [{"id": "t%d" % i, "files": ["src/m%d/x.go" % i, "src/m%d/y.go" % i]} for i in range(1000)])
timed("stress-1000-one-top-dir-deep",
      [{"id": "t%d" % i, "files": ["/".join(["src"] + ["d%d" % k for k in range(29)] + ["f%d" % i]),
                                   "/".join(["src"] + ["d%d" % k for k in range(29)] + ["g%d" % i])]}
       for i in range(1000)])

# ---- every real plan in the repo that PyYAML loads reads the same through the tool
if yaml is None:
    skip("real-plans-differential")
else:
    real = []
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in (".git", ".wt", "node_modules")]
        real += [os.path.join(dp, f) for f in fn if f.startswith("change-plan") and f.endswith(".yaml")]
    real.sort()
    loaded = refused = 0
    for p in real:
        with open(p, encoding="utf-8") as fh:
            text = fh.read()
        try:
            ref = yaml.safe_load(text)
        except yaml.YAMLError:
            r, o, e = cli([p])
            check("real-invalid-yaml-refused " + p, r == 2, o + e)
            refused += 1
            print("INFO refused (invalid YAML): %s" % os.path.relpath(p, root))
            continue
        try:
            mine = view(pd.load_plan(p, text))
        except pd.ParseError as ex:
            refused += 1
            print("INFO refused (%s): %s" % (ex, os.path.relpath(p, root)))
            continue
        check("real-view " + p, mine == view(ref["tasks"]), p)
        loaded += 1
    print("INFO real plans: %d found, %d loaded and equal to PyYAML, %d refused" % (len(real), loaded, refused))
    check("real-plans-found", len(real) > 0, root)

# ---- the soundness oracle (shares no code with the tool)
NAMES = ["a", "b", "c", "ab", "A", "B", "Ab", "x.d", "v1.2", ".git", ".hidden", "f.go", "F.GO", "a.go",
         "b.md", "Makefile", "ß", "é", "é", "İ", "a b", "x-y_z", "_", "ba.d", "é.go"]
DIRS = ["a", "b", "A", "x.d", ".git", "ab", "é", "é", "v1.2"]
LITS = ["a", "b", "c", "ab", "A", "x.d", ".git", "f.go", "a.go", "ß", "é", "é", "İ", "v1.2"]
FIRST = ["a", "b", "A", "x.d", ".git", "\u00e9", "e\u0301", "a*", "[ab]", "?", "{a,b}", "{a/b,c}"]
WILDS = ["*", "?", "[ab]", "[!a]", "[a-c]", "*.go", "a*", "?.go", "*b", "a?", "v[0-9].*", "[A-z]", "??",
         "a*b", "{a,b}", "{a,{b,c}}", "{a/b,c}", "{a}", "{x.d,f.go}", "**", "**"]

# round 3: NFC and NFD, canonical caseless pairs, mixed case, trailing dots, shell characters
NAMES += ["\u00e9", "e\u0301", "\u00c9", "E\u0301", "\u1fb7", "\u1fbc\u0342", "\u1fb3\u0342", "ss", "SS",
          "\u212a", "k", "K", "aB", "A.GO", "a.", "a..", "+(a|b).go", "@(a|b).go", "!(x).go", "$V.go", "a$", "`a`"]
DIRS += ["\u00e9", "e\u0301", "\u1fb7", "a."]
LITS += ["\u00e9", "e\u0301", "\u1fb7", "\u1fbc\u0342", "a.", "aB", "ss", "K",
         "+(a|b).go", "@(a|b).go", "!(x).go", "$V.go"]
FIRST += ["a", "A", "b", "ab", "a."]


def universe():
    R = random.Random(20261127)
    u = {(n,) for n in NAMES}
    u |= {(d, n) for d in DIRS for n in NAMES}
    base = len(u)
    while len(u) < base + 150:
        k = R.randint(3, 5)
        u.add(tuple(R.choice(DIRS if i < k - 1 else NAMES) for i in range(k)))
    return sorted(u)


def patterns(R, n):
    out = set()
    while len(out) < n:
        parts = []
        for _ in range(R.randint(1, 3)):
            if not parts:
                parts.append(R.choice(FIRST) if R.random() < 0.7 else R.choice(WILDS))
            else:
                parts.append(R.choice(LITS) if R.random() < 0.55 else R.choice(WILDS))
        s = ""
        for i, c in enumerate(parts):
            s += (R.choice(["/", "/", "/", "/", "//"]) if i else "") + c
        if R.random() < 0.1:
            s = "./" + s
        if R.random() < 0.15:
            s += "/"
        out.add(s)
    return sorted(out)


def o_expand(s):
    m = re.search(r"\{([^{}]*)\}", s)
    if not m:
        return [s]
    body = m.group(1)
    alts = body.split(",") if "," in body else [body, "" + body + ""]
    res = []
    for a in alts:
        res += o_expand(s[:m.start()] + a + s[m.end():])
    return res


_LOW = {ord(c): ord(c) + 32 for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}


def _canon(c):
    n = unicodedata.normalize
    return n("NFD", n("NFD", c).casefold())


# "the same file" = the UNION of every relation a real filesystem may apply: byte-equal,
# ASCII-case-insensitive, NFC, NFD, canonical caseless (NFD(casefold(NFD))), trailing-dot-insensitive
KEYS = [lambda c: c,
        lambda c: c.translate(_LOW),
        lambda c: unicodedata.normalize("NFC", c),
        lambda c: unicodedata.normalize("NFD", c),
        _canon,
        lambda c: c.rstrip("."),
        lambda c: _canon(c).rstrip(".")]
SHELLISH = re.compile(r"[()|$!`^#&;<>'\" ]")


def shellish(c):
    """a shell or extglob character could make this component match anything"""
    return "*" if SHELLISH.search(c) else c


_cm = {}


def cmatch(name, pat):
    k = (name, pat)
    if k not in _cm:
        _cm[k] = fnmatch.fnmatchcase(name, pat)
    return _cm[k]


def covers(pc, path):
    if "**" not in pc:
        return len(pc) <= len(path) and all(cmatch(path[i], c) for i, c in enumerate(pc))
    memo = {}

    def go(i, j):
        if i == len(pc):
            return True
        if (i, j) in memo:
            return memo[(i, j)]
        if pc[i] == "**":
            r = go(i + 1, j) or (j < len(path) and go(i, j + 1))
        else:
            r = j < len(path) and cmatch(path[j], pc[i]) and go(i + 1, j + 1)
        memo[(i, j)] = r
        return r
    return go(0, 0)


_UK = {}


def matched(pattern, uni):
    hit = set()
    if id(uni) not in _UK:
        _UK[id(uni)] = [[tuple(K(c) for c in path) for path in uni] for K in KEYS]
    for e in o_expand(pattern):
        e = e.replace("\ue000", "{").replace("\ue001", "}")
        pc = [shellish(c) for c in e.split("/") if c not in ("", ".")]
        for ki, K in enumerate(KEYS):
            kc = [K(c) for c in pc]
            for idx, kp in enumerate(_UK[id(uni)][ki]):
                if idx not in hit and covers(kc, kp):
                    hit.add(idx)
    return hit


UNI = universe()
CACHE = {}


def run_oracle():
    uni, cache = UNI, CACHE
    R = random.Random(7)
    pats = patterns(R, 500)
    pairs = fn = shared = reported_disjoint = disjoint = 0
    codes = set()
    for _ in range(2500):
        p, q = R.choice(pats), R.choice(pats)
        for x in (p, q):
            if x not in cache:
                cache[x] = matched(x, uni)
        share = bool(cache[p] & cache[q])
        errs = pd.validate([{"id": "p", "files": [p]}, {"id": "q", "files": [q]}])[1]
        codes |= {e["code"] for e in errs}
        pairs += 1
        if share:
            shared += 1
            fn += 0 if errs else 1
        else:
            disjoint += 1
            reported_disjoint += 1 if errs else 0
    return len(uni), pairs, shared, fn, reported_disjoint / max(1, disjoint), codes


nu, npairs, nshared, nfn, over, codes = run_oracle()
check("oracle-sizes", nu >= 400 and npairs >= 2000 and nshared >= 300, (nu, npairs, nshared))
check("oracle-zero-false-negatives", nfn == 0, "%d false negatives" % nfn)
check("oracle-grammar-clean", codes <= {"file_conflict", "too_broad"}, codes)
print("INFO oracle: %d paths, %d pairs, %d share a path, %d false negatives, over-report rate %.1f%%"
      % (nu, npairs, nshared, nfn, 100 * over))
real_fc = pd.find_conflicts
pd.find_conflicts = lambda entries: {}
try:
    cu, cp, cs, cfn, _, _ = run_oracle()
finally:
    pd.find_conflicts = real_fc
check("oracle-canary", cfn > 0, "the oracle did not notice an overlap check that always says disjoint")
print("INFO oracle canary (always-disjoint overlap): %d false negatives found" % cfn)

print("RESULT %d %d %d" % (N["ok"], N["fail"], N["skip"]))
PY

hout=""
hrc=0
hout="$(python3 -I -B "$T/h.py" "$PD" "$T" "$ROOT" 2>&1)" || hrc=$?
got=0
while IFS= read -r line; do
  case "$line" in
    RESULT\ *)
      got=1
      read -r _ hp hf hs <<<"$line"
      pass=$((pass + hp))
      fail=$((fail + hf))
      skipped=$((skipped + hs))
      ;;
    FAIL\ * | SKIPPED\ * | INFO\ *) printf '%s\n' "$line" ;;
    *) [ "$hrc" -eq 0 ] || printf '%s\n' "$line" ;;
  esac
done <<<"$hout"
[ "$got" = 1 ] && ok || bad "in-process harness produced no RESULT line (rc=$hrc)"

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

if [ "$skipped" -gt 0 ]; then
  printf 'plan-dag-selftest: %d ok, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
else
  printf 'plan-dag-selftest: %d ok, %d failed\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
