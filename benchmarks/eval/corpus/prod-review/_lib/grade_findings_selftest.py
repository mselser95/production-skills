#!/usr/bin/env python3
"""Selftest for grade_findings.py (stdlib only, in-process).

  grade_findings_selftest.py              run every case; exit 0 all pass, 1 any fail, 2 none ran
  GRADE_PY=<copy> ...                     grade with another copy of the grader
  grade_findings_selftest.py --mutations  prove each guard non-vacuous: mutate a temp copy of the
                                          grader, rerun the cases, expect RED (prints one line each)
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

T0 = time.time()
HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.dirname(HERE)
GRADER = os.environ.get("GRADE_PY") or os.path.join(HERE, "grade_findings.py")
SCHEMA = os.path.join(HERE, "output.schema.json")


def load(path):
    spec = importlib.util.spec_from_file_location("grade_findings_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


G = load(GRADER)
RESULTS = []   # (name, ok, detail)


def sh(cmd, cwd, env=None):
    subprocess.run(cmd, cwd=cwd, check=True, env=env, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


def make_repo(root):
    os.makedirs(root)
    write(root, "ledger.go", "package ledger\n" + "// line\n" * 40)
    write(root, "other.go", "package ledger\n" + "// line\n" * 40)
    write(root, "ledger_test.go", "package ledger\n")
    write(root, "go.mod", "module example.com/l\n")
    write(root, "notes.txt", "plain\n")
    write(root, "production.yaml", "version: v1\n")
    write(root, ".prod/context/change-plan.yaml", "a: 1\n" * 10)
    write(root, "sub/dir.go", "package sub\n")
    sh(["git", "init", "-q"], root)
    sh(["git", "add", "-A"], root)
    sh(["git", "-c", "user.name=t", "-c", "user.email=t@e.invalid", "commit", "-qm", "base"], root)


TMP = tempfile.mkdtemp(prefix="gfst.")
BASE = os.path.join(TMP, "base")
make_repo(BASE)
EXPECTED = os.path.join(TMP, "expected.diffhash")
with open(EXPECTED, "w") as f:
    f.write(G.tree_hash(BASE) + "\n")

# Spawning git costs ~50 ms here, so hashes are not recomputed per case: the untouched
# base was hashed once above, and the modified copies are hashed in parallel (see run_mods).
REAL_HASH = G.tree_hash
HASHES = {BASE: G.tree_hash(BASE)}
G.tree_hash = lambda w: HASHES[w] if w in HASHES else REAL_HASH(w)

F, S, E = "ledger.go", 10, 12          # seeded task: defect file and range; window 7..15
_n = [0]


def run(workdir, content, kind="seeded", expected=EXPECTED, output=None):
    """-> (exit code, metrics dict or None, stderr)"""
    if output is None:
        _n[0] += 1
        output = os.path.join(TMP, "out%d.txt" % _n[0])
        mode = "wb" if isinstance(content, bytes) else "w"
        with open(output, mode) as f:
            f.write(content)
    argv = ["--workdir", workdir, "--output", output, "--expected", expected]
    argv += ["--clean"] if kind == "clean" else ["--file", F, "--start", str(S), "--end", str(E)]
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            G.main(argv)
        except SystemExit as e:
            code = e.code or 0
    lines = out.getvalue().strip().splitlines()
    return code, (json.loads(lines[-1]) if len(lines) == 1 else None), err.getvalue()


def M(kind="seeded", **kw):
    m = dict(found=0, missed=0 if kind == "clean" else 1, false_positives=0,
             non_defect_findings=0, nonspecific_findings=0, context_findings=0,
             unknown_file_findings=0, modified_files=False, parse_error=False,
             schema_error=False, kind=kind)
    m.update(kw)
    return m


def fd(file, a, b=None, cls="defect", sev="blocker", summary="s"):
    return {"file": file, "line_start": a, "line_end": a if b is None else b,
            "class": cls, "severity": sev, "summary": summary}


def doc(*findings, verdict=None):
    if verdict is None:
        verdict = "defects_found" if any(f.get("class") == "defect" for f in findings) else "no_defects"
    return {"verdict": verdict, "findings": list(findings)}


def case(name, content, code, metrics, kind="seeded", wd=BASE):
    try:
        if isinstance(content, dict):
            content = json.dumps(content)
        got_code, got, err = run(wd, content, kind)
        bad = []
        if got_code != code:
            bad.append("exit %r != %r" % (got_code, code))
        if got != metrics:
            if got is None:
                bad.append("no single JSON line on stdout")
            else:
                bad.append("metrics differ: " + ", ".join(
                    "%s=%r (want %r)" % (k, got.get(k), metrics.get(k))
                    for k in metrics if got.get(k) != metrics.get(k)))
        if "Traceback" in err:
            bad.append("traceback on stderr")
        RESULTS.append((name, not bad, "; ".join(bad)))
    except Exception as e:   # a crash is a failed case, never a skipped one
        RESULTS.append((name, False, "crashed: %r" % (e,)))


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), "" if ok else detail))


def hit(**kw):
    return M(found=1, missed=0, **kw)


# ---- seeded: window, width, class, severity ---------------------------------
case("seeded hit", doc(fd(F, 11)), 0, hit())
case("window: start-3 hits", doc(fd(F, S - 3)), 0, hit())
case("window: start-4 misses (FP)", doc(fd(F, S - 4)), 1, M(false_positives=1))
case("window: end+3 hits", doc(fd(F, E + 3)), 0, hit())
case("window: end+4 misses (FP)", doc(fd(F, E + 4)), 1, M(false_positives=1))
case("range ending at start-3 hits", doc(fd(F, 2, S - 3)), 0, hit())
case("range ending at start-4 misses", doc(fd(F, 2, S - 4)), 1, M(false_positives=1))
case("12-line range overlapping is found", doc(fd(F, S, S + 11)), 0, hit())
case("13-line range overlapping is neutral", doc(fd(F, S, S + 12)), 1, M(nonspecific_findings=1))
case("13-line range elsewhere is an FP", doc(fd(F, 25, 37)), 1, M(false_positives=1, nonspecific_findings=1))
case("13-line neutral + a specific hit still found", doc(fd(F, S, S + 12), fd(F, 11)), 0,
     hit(nonspecific_findings=1))
for cls in ("missing_test", "note", "not_validated"):
    case("right line, class %s: not found" % cls, doc(fd(F, 11, cls=cls)), 1, M(non_defect_findings=1))
case("severity ignored: nit defect is found", doc(fd(F, 11, sev="nit")), 0, hit())
case("severity ignored: warning defect is found", doc(fd(F, 11, sev="warning")), 0, hit())
case("severity ignored: blocker note is not a defect", doc(fd(F, 11, cls="note", sev="blocker")), 1,
     M(non_defect_findings=1))
case("blocker missing_test elsewhere is no FP", doc(fd(F, 11), fd("other.go", 3, cls="missing_test", sev="blocker")),
     0, hit(non_defect_findings=1))
case("no findings, no_defects: miss", doc(), 1, M())


def fps(n, start=20):
    return [fd("other.go", start + i) for i in range(n)]


case("FP cap: 5 elsewhere passes", doc(fd(F, 11), *fps(5)), 0, hit(false_positives=5))
case("FP cap: 6 elsewhere fails", doc(fd(F, 11), *fps(6)), 1, hit(false_positives=6))
case("distinct pairs: the same line 4 times is one FP", doc(fd(F, 11), *([fd("other.go", 20)] * 4)), 0,
     hit(false_positives=1))
case("distinct pairs: same start, different end is one FP",
     doc(fd(F, 11), fd("other.go", 20, 21), fd("other.go", 20, 25)), 0, hit(false_positives=1))
case("distinct pairs: same line in two files is two FPs",
     doc(fd(F, 11), fd("other.go", 20), fd("ledger_test.go", 20)), 0, hit(false_positives=2))
case("duplicate hits count once for found", doc(fd(F, 11), fd(F, 11), fd(F, 12)), 0, hit())
case("wrong file, right line", doc(fd("other.go", 11)), 1, M(false_positives=1))
case("test file counts as a code file", doc(fd("ledger_test.go", 1)), 1, M(false_positives=1))

# ---- files --------------------------------------------------------------------
case("unknown file ignored and counted", doc(fd(F, 11), fd("ghost.go", 11)), 0, hit(unknown_file_findings=1))
case("a directory is not a file", doc(fd(F, 11), fd("sub", 1)), 0, hit(unknown_file_findings=1))
case("path escaping the workdir is unknown", doc(fd(F, 11), fd("../ledger.go", 11)), 0,
     hit(unknown_file_findings=1))
case("./ prefix normalised", doc(fd("./" + F, 11)), 0, hit())
case("absolute path under the workdir normalised", doc(fd(os.path.join(BASE, F), 11)), 0, hit())
case("absolute path outside the workdir is unknown", doc(fd(F, 11), fd("/etc/hosts", 1)), 0,
     hit(unknown_file_findings=1))
case("only unknown files: miss", doc(fd("ghost.go", 11)), 1, M(unknown_file_findings=1))
case("context findings ignored and counted",
     doc(fd(F, 11), fd(".prod/context/change-plan.yaml", 5), fd("production.yaml", 1)), 0,
     hit(context_findings=2))
case("context finding cannot be the hit", doc(fd(".prod/context/change-plan.yaml", 11)), 1,
     M(context_findings=1))

# ---- clean --------------------------------------------------------------------
case("clean: no findings passes", doc(), 0, M("clean"), "clean")
case("clean: non-defect findings only passes",
     doc(fd(F, 11, cls="missing_test"), fd("other.go", 5, cls="note", sev="blocker"),
         fd(F, 3, cls="not_validated", sev="warning")), 0, M("clean", non_defect_findings=3), "clean")
case("clean: one specific defect fails", doc(fd(F, 11)), 1, M("clean", false_positives=1), "clean")
case("clean: one whole-file defect fails", doc(fd(F, 1, 400)), 1,
     M("clean", false_positives=1, nonspecific_findings=1), "clean")
case("clean: defect on a test file fails", doc(fd("ledger_test.go", 1)), 1, M("clean", false_positives=1),
     "clean")
case("clean: context defect is ignored",
     doc(fd(".prod/context/change-plan.yaml", 2), fd("production.yaml", 1)), 0,
     M("clean", context_findings=2), "clean")
case("clean: defect on an unknown file is ignored", doc(fd("ghost.go", 2), fd(F, 1, cls="note")), 0,
     M("clean", unknown_file_findings=1, non_defect_findings=1), "clean")
case("clean: same line twice is one FP", doc(fd(F, 4), fd(F, 4)), 1, M("clean", false_positives=1), "clean")

# ---- verdict consistency --------------------------------------------------------
case("verdict no_defects with a defect: schema error", doc(fd(F, 11), verdict="no_defects"), 1,
     M(schema_error=True))
case("verdict defects_found with no defect: schema error", doc(fd(F, 11, cls="note"), verdict="defects_found"), 1,
     M(schema_error=True))
case("clean: verdict contradicting findings: schema error", doc(fd(F, 1), verdict="no_defects"), 1,
     M("clean", schema_error=True), "clean")
case("clean: defects_found with no findings: schema error", doc(verdict="defects_found"), 1,
     M("clean", schema_error=True), "clean")

# ---- unparsable and invalid documents ---------------------------------------------
GOOD = doc(fd(F, 11))
for name, text in [("empty file", ""), ("whitespace only", " \n\t\n"), ("LGTM", "LGTM"),
                   ("truncated JSON", json.dumps(GOOD)[:-9]),
                   ("prose before the JSON", "Here is my review:\n" + json.dumps(GOOD)),
                   ("two fenced blocks", "```json\n%s\n```\n```json\n%s\n```" % ((json.dumps(GOOD),) * 2)),
                   ("JSON followed by prose", json.dumps(GOOD) + "\nHope this helps"),
                   ("invalid utf-8 bytes", b"\xff\xfe\x00{")]:
    case("parse error: " + name, text, 1, M(parse_error=True))
    case("parse error (clean): " + name, text, 1, M("clean", parse_error=True), "clean")


def mutated(path_edit):
    d = json.loads(json.dumps(GOOD))
    path_edit(d)
    return d


bad_docs = {
    "a JSON array": [GOOD],
    "a JSON string": "LGTM",
    "missing top-level key": {"verdict": "defects_found"},
    "extra top-level key": dict(GOOD, extra=1),
    "missing finding key": mutated(lambda d: d["findings"][0].pop("severity")),
    "extra finding key": mutated(lambda d: d["findings"][0].update(confidence="high")),
    "wrong class enum": mutated(lambda d: d["findings"][0].update({"class": "bug"})),
    "wrong severity enum": mutated(lambda d: d["findings"][0].update(severity="high")),
    "wrong verdict enum": dict(GOOD, verdict="fail"),
    "string line number": mutated(lambda d: d["findings"][0].update(line_start="11")),
    "float line number": mutated(lambda d: d["findings"][0].update(line_start=11.0)),
    "bool line number": mutated(lambda d: d["findings"][0].update(line_start=True)),
    "negative line": mutated(lambda d: d["findings"][0].update(line_start=-3, line_end=11)),
    "zero line": mutated(lambda d: d["findings"][0].update(line_start=0, line_end=11)),
    "line_end < line_start": mutated(lambda d: d["findings"][0].update(line_start=12, line_end=11)),
    "non-string file": mutated(lambda d: d["findings"][0].update(file=7)),
    "non-string summary": mutated(lambda d: d["findings"][0].update(summary=None)),
    "findings not an array": {"verdict": "no_defects", "findings": {}},
    "finding not an object": {"verdict": "no_defects", "findings": ["x"]},
    "null document": None,
}
for name, d in bad_docs.items():
    case("schema error: " + name, json.dumps(d), 1, M(schema_error=True))
case("schema error (clean): extra key", json.dumps(dict(doc(), extra=1)), 1, M("clean", schema_error=True), "clean")
case("schema error (clean): bad enum", json.dumps(doc(fd("other.go", 3, cls="nit"))), 1,
     M("clean", schema_error=True), "clean")

# ---- fences and whitespace -----------------------------------------------------------
j = json.dumps(GOOD)
case("json fence accepted", "```json\n%s\n```" % j, 0, hit())
case("bare fence accepted", "```\n%s\n```\n" % j, 0, hit())
case("fence with surrounding whitespace accepted", "\n\n  ```json\n%s\n```  \n\n" % j, 0, hit())
case("pretty-printed JSON with whitespace accepted", "\n  " + json.dumps(GOOD, indent=2) + "\n\n", 0, hit())
case("CRLF fence accepted", "```json\r\n%s\r\n```" % j, 0, hit())


# ---- modification --------------------------------------------------------------------
def fresh(name):
    d = os.path.join(TMP, "mod-" + name)
    shutil.copytree(BASE, d, symlinks=True)
    return d


MODS = []


def mod_case(name, action, code, extra, content=None, metrics=None):
    d = fresh(name.replace(" ", "_").replace("/", "_"))
    action(d)
    MODS.append(("modification: " + name, doc(fd(F, 11)) if content is None else content, code,
                 hit(**extra) if metrics is None else metrics, d))


def run_mods():
    dirs = [m[4] for m in MODS]
    with ThreadPoolExecutor(8) as ex:
        for d, h in zip(dirs, ex.map(REAL_HASH, dirs)):
            HASHES[d] = h
    for name, content, code, metrics, d in MODS:
        case(name, content, code, metrics, wd=d)


def append(rel):
    return lambda d: write(d, rel, open(os.path.join(d, rel)).read() + "// edit\n")


mod_case("tracked Go file edited", append("other.go"), 1, {"modified_files": True})
mod_case("the defect file edited", append(F), 1, {"modified_files": True})
mod_case("context file edited", append(".prod/context/change-plan.yaml"), 1, {"modified_files": True})
mod_case("production.yaml edited", append("production.yaml"), 1, {"modified_files": True})
mod_case("non-Go tracked file edited", append("notes.txt"), 1, {"modified_files": True})
mod_case("tracked file deleted", lambda d: os.remove(os.path.join(d, "other.go")), 1,
         {"modified_files": True})
mod_case("new untracked .go", lambda d: write(d, "new.go", "package x\n"), 1, {"modified_files": True})
mod_case("new untracked .yaml", lambda d: write(d, "ci.yaml", "a: 1\n"), 1, {"modified_files": True})
mod_case("tracked file staged", lambda d: (append("other.go")(d), sh(["git", "add", "other.go"], d)), 1,
         {"modified_files": True})
mod_case("untracked .claude/ ignored", lambda d: write(d, ".claude/settings.json", "{}"), 0, {})
mod_case("untracked .codex/ ignored", lambda d: write(d, ".codex/x.go", "package x\n"), 0, {})
mod_case("untracked AGENTS.md ignored", lambda d: write(d, "AGENTS.md", "x"), 0, {})
mod_case("untracked CLAUDE.md ignored", lambda d: write(d, "CLAUDE.md", "x"), 0, {})
mod_case("untracked non-source file ignored", lambda d: write(d, "scratch.txt", "x"), 0, {})
mod_case("modified tree on an unparsable output still reports it", lambda d: write(d, "new.go", "x"), 1, {},
         content="LGTM", metrics=M(parse_error=True, modified_files=True))
run_mods()

# ---- grader errors (exit 2) ------------------------------------------------------------
out = os.path.join(TMP, "outE.txt")
with open(out, "w") as f:
    f.write(json.dumps(GOOD))
for name, kw, want in [
    ("missing workdir", dict(workdir=os.path.join(TMP, "nope"), output=out), 2),
    ("missing output file", dict(workdir=BASE, output=os.path.join(TMP, "none.txt")), 2),
    ("missing expected.diffhash", dict(workdir=BASE, output=out, expected=os.path.join(TMP, "none.hash")), 2),
]:
    try:
        c, m, err = run(kw["workdir"], "", output=kw["output"], expected=kw.get("expected", EXPECTED))
        check("exit 2: " + name, c == want and m is not None and "Traceback" not in err, "exit %r" % c)
    except Exception as e:
        check("exit 2: " + name, False, "crashed: %r" % (e,))
check("exit 2 leaves a JSON line with kind", run(os.path.join(TMP, "nope"), "")[1] == M(), "")
c, m, err = run(BASE, "", output=out)
check("a seeded run without --file/--start/--end is exit 2",
      subprocess.run([sys.executable, "-I", GRADER, "--workdir", BASE, "--output", out, "--expected", EXPECTED],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 2)

JOBS = []   # slow subprocess checks, run in parallel at the end

# ---- the schema file ---------------------------------------------------------------------
ALLOWED = {"type", "properties", "required", "additionalProperties", "items", "enum"}


def portable(s, path="$"):
    """Return a list of violations of the common strict subset both hosts accept."""
    bad = []
    if not isinstance(s, dict):
        return ["%s: not an object" % path]
    for k in s:
        if k not in ALLOWED:
            bad.append("%s: keyword %s is outside the portable subset" % (path, k))
    t = s.get("type")
    if not isinstance(t, str):
        bad.append("%s: type must be one string" % path)
    if "enum" in s and (not isinstance(s["enum"], list) or any(not isinstance(v, str) for v in s["enum"])):
        bad.append("%s: enum must be a list of strings (no null)" % path)
    if t == "object":
        props = s.get("properties")
        if not isinstance(props, dict):
            return bad + ["%s: object without properties" % path]
        if s.get("additionalProperties") is not False:
            bad.append("%s: additionalProperties must be false" % path)
        if sorted(s.get("required", [])) != sorted(props):
            bad.append("%s: required must list every property" % path)
        for k, v in props.items():
            bad += portable(v, path + "." + k)
    elif t == "array":
        bad += portable(s["items"], path + "[]") if "items" in s else ["%s: array without items" % path]
    elif t not in ("string", "integer"):
        bad.append("%s: type %r not allowed" % (path, t))
    return bad


def valid(s, v):
    t = s["type"]
    if "enum" in s and v not in s["enum"]:
        return False
    if t == "object":
        return (isinstance(v, dict) and set(v) == set(s["properties"])
                and all(valid(s["properties"][k], v[k]) for k in v))
    if t == "array":
        return isinstance(v, list) and all(valid(s["items"], x) for x in v)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    return isinstance(v, str)


try:
    with open(SCHEMA) as f:
        schema = json.load(f)
    check("schema: valid JSON", True)
    check("schema: portable subset", not portable(schema), "; ".join(portable(schema)))
    check("schema: the validator rejects what it should",
          not valid(schema, {"verdict": "no_defects"}) and not valid(schema, dict(GOOD, x=1))
          and not valid(schema, mutated(lambda d: d["findings"][0].update(line_start="1")))
          and valid(schema, GOOD))
    check("schema: portability check catches a loose schema",
          bool(portable({"type": "object", "properties": {"a": {"type": ["string", "null"]}}})))
    disagree = [i for i, d in enumerate(bad_docs.values())
                if d is not None and G.validate(d) is None and not valid(schema, d)]
    check("schema: every document the grader accepts validates against it", not disagree, str(disagree))
    refs = sorted(os.path.join(CORPUS, d, "reference", "solve.sh") for d in os.listdir(CORPUS)
                  if os.path.isfile(os.path.join(CORPUS, d, "reference", "solve.sh")))
    check("schema: found the reference solutions", len(refs) >= 1, "none under %s" % CORPUS)

    def ref_job(r):
        o = os.path.join(TMP, "ref-%s.json" % os.path.basename(os.path.dirname(os.path.dirname(r))))
        p = subprocess.run(["bash", r, BASE, o], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            with open(o) as f:
                d = json.load(f)
            ok = p.returncode == 0 and valid(schema, d) and G.validate(d) is None and G.verdict_consistent(d)
        except (OSError, ValueError):
            ok = False
        return ("reference output validates: " + os.path.basename(os.path.dirname(os.path.dirname(r))), ok,
                "" if ok else "invalid or unreadable output")
    JOBS.extend((lambda r=r: ref_job(r)) for r in refs)
except (OSError, ValueError) as e:
    check("schema: loads", False, repr(e))

# ---- end to end through three real task grade.sh -------------------------------------------
_wd = {}
_lock = threading.Lock()


def task_workdir(task):
    with _lock:
        if task not in _wd:
            d = os.path.join(TMP, "task-" + task)
            shutil.copytree(os.path.join(CORPUS, task, "fixture"), d)
            sh(["git", "init", "-q"], d)
            sh(["git", "add", "-A"], d)
            sh(["git", "-c", "user.name=t", "-c", "user.email=t@e.invalid", "commit", "-qm", "fixture"], d)
            sh(["bash", os.path.join(CORPUS, task, "fixture.setup.sh")], d)
            _wd[task] = d
        return _wd[task]


def e2e(name, task, writer, want_code, want):
    JOBS.append(lambda: _e2e(name, task, writer, want_code, want))


def _e2e(name, task, writer, want_code, want):
    try:
        wd = task_workdir(task)
        out = os.path.join(TMP, "e2e-%s-%s.json" % (task, writer.__name__))
        writer(task, wd, out)
        env = dict(os.environ, GRADE_PY=GRADER)
        p = subprocess.run(["bash", os.path.join(CORPUS, task, "grade.sh"), wd, out], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        m = json.loads(p.stdout.strip().splitlines()[-1])
        bad = [k for k, v in want.items() if m.get(k) != v]
        ok = p.returncode == want_code and not bad
        return (name, ok, "" if ok else "exit %r want %r; metrics off: %s" % (p.returncode, want_code, bad))
    except Exception as e:
        return (name, False, "crashed: %r" % (e,))


def ref_writer(task, wd, out):
    subprocess.run(["bash", os.path.join(CORPUS, task, "reference", "solve.sh"), wd, out], check=True)


def empty_writer(task, wd, out):
    open(out, "w").close()


def defect_writer(task, wd, out):
    with open(out, "w") as f:
        json.dump(doc(fd("retry.go", 20, 21)), f)


e2e("e2e: seeded-01 reference passes", "seeded-01-ledger-fee", ref_writer, 0,
    {"found": 1, "false_positives": 0, "modified_files": False, "kind": "seeded"})
e2e("e2e: seeded-01 empty output fails cleanly", "seeded-01-ledger-fee", empty_writer, 1,
    {"found": 0, "parse_error": True, "modified_files": False})
e2e("e2e: clean-01 one defect finding fails", "clean-01-retry-backoff", defect_writer, 1,
    {"false_positives": 1, "kind": "clean", "modified_files": False})


with ThreadPoolExecutor(8) as _ex:
    RESULTS.extend(_ex.map(lambda j: j(), JOBS))


# ---- report ------------------------------------------------------------------------------------
def report(t0):
    failed = [r for r in RESULTS if not r[1]]
    for name, _, detail in failed:
        print("FAIL %s: %s" % (name, detail))
    print("grade_findings selftest: %d/%d passed in %.1fs" % (len(RESULTS) - len(failed), len(RESULTS),
                                                             time.time() - t0))
    shutil.rmtree(TMP, ignore_errors=True)
    if not RESULTS:
        return 2
    return 1 if failed else 0


MUTATIONS = [
    ("window slack 3 -> 300", "SLACK = 3", "SLACK = 300"),
    ("class check removed (any class is a defect)", 'return f["class"] == "defect"', "return True"),
    ("severity used instead of class", 'return f["class"] == "defect"', 'return f["severity"] == "blocker"'),
    ("FP cap -> 10**9", "MAX_FP_SEEDED = 5", "MAX_FP_SEEDED = 10**9"),
    ("specific-width cap removed", "MAX_SPECIFIC_WIDTH = 12", "MAX_SPECIFIC_WIDTH = 10**9"),
    ("context exclusion removed", 'return p.startswith(".prod/") or p == "production.yaml"', "return False"),
    ("modification check off", "modified = tree_hash(a.workdir) != expected", "modified = False"),
    ("verdict-consistency check removed", 'return has == (doc["verdict"] == "defects_found")', "return True"),
    ("schema validation removed (extra key accepted)", "if set(f) != set(KEYS_FINDING):",
     "if not set(KEYS_FINDING) <= set(f):"),
    ("FP counting by finding, not distinct (file, line)", 'len({(f["file"], f["line_start"]) for f in far})',
     "len(far)"),
]


def mutations():
    with open(GRADER) as f:
        src = f.read()
    bad = 0
    for name, old, new in MUTATIONS:
        if src.count(old) != 1:
            print("ERROR %s: pattern found %d times in the grader" % (name, src.count(old)))
            bad += 1
            continue
        d = tempfile.mkdtemp(prefix="gfmut.")
        cp = os.path.join(d, "grade_findings.py")
        with open(cp, "w") as f:
            f.write(src.replace(old, new))
        p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "grade_findings_selftest.py")],
                           env=dict(os.environ, GRADE_PY=cp), stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, cwd=d)
        lines = p.stdout.strip().splitlines()
        first = next((ln for ln in lines if ln.startswith("FAIL ")), "")
        shutil.rmtree(d, ignore_errors=True)
        if p.returncode == 1:
            print("RED   %s -> %s | %s" % (name, lines[-1].split(": ", 1)[-1], first[:110]))
        else:
            print("GREEN %s -> selftest exit %s (the guard is not covered)" % (name, p.returncode))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    if "--mutations" in sys.argv:
        shutil.rmtree(TMP, ignore_errors=True)
        sys.exit(mutations())
    sys.exit(report(T0))
