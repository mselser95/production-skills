#!/usr/bin/env python3
"""Deterministic grader shared by every prod-review corpus task (stdlib only).

The agent returns ONE JSON document conforming to output.schema.json; this
grader only compares data, it never interprets prose.

Usage:
  grade_findings.py --workdir W --output O --expected HASHFILE --file F --start N --end M
  grade_findings.py --workdir W --output O --expected HASHFILE --clean
  grade_findings.py --workdir W --print-hash        (regenerates expected.diffhash)

Prints exactly one JSON line. Exit 0 pass, 1 fail, 2 grader error.
See _lib/README.md for the pass rules and the modification rule.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

SLACK = 3
MAX_FP_SEEDED = 5
MAX_SPECIFIC_WIDTH = 12   # a finding wider than this earns no credit

KEYS_DOC = ("verdict", "findings")
KEYS_FINDING = ("file", "line_start", "line_end", "class", "severity", "summary")
VERDICTS = ("defects_found", "no_defects")
CLASSES = ("defect", "missing_test", "not_validated", "note")
SEVERITIES = ("blocker", "warning", "nit")

FENCE = re.compile(r"\A```(?:json)?[ \t]*\r?\n(.*?)\r?\n?```\Z", re.S)


def emit(m):
    order = ("found", "missed", "false_positives", "non_defect_findings",
             "nonspecific_findings", "context_findings", "unknown_file_findings",
             "modified_files", "parse_error", "schema_error", "kind")
    print(json.dumps({k: m[k] for k in order}, separators=(",", ":")))


def blank(kind, **kw):
    m = dict(found=0, missed=0 if kind == "clean" else 1, false_positives=0,
             non_defect_findings=0, nonspecific_findings=0, context_findings=0,
             unknown_file_findings=0, modified_files=False, parse_error=False,
             schema_error=False, kind=kind)
    m.update(kw)
    return m


def fail_error(msg, kind):
    sys.stderr.write("grade_findings: %s\n" % msg)
    emit(blank(kind))
    sys.exit(2)


def git(workdir, *args):
    return subprocess.run(["git", "-C", workdir] + list(args), check=True,
                          stdout=subprocess.PIPE).stdout


UNTRACKED_SOURCE = (".go", ".mod", ".sum", ".yaml", ".yml")
HOST_DIRS = (".claude/", ".codex/", ".agents/")
HOST_FILES = ("CLAUDE.md", "AGENTS.md")


def tree_hash(workdir):
    """Hash of (1) every TRACKED file (index blob id, or the on-disk content
    when `git status` lists the path as changed; a deleted one hashes as
    MISSING), (2) the porcelain status lines of tracked paths, (3) UNTRACKED
    files that look like module sources (.go .mod .sum .yaml .yml) outside
    host droppings (.claude/ .codex/ .agents/ CLAUDE.md AGENTS.md).
    Two git calls only."""
    h = hashlib.sha256()
    staged = git(workdir, "ls-files", "-z", "-s").decode("utf-8", "replace")
    status = git(workdir, "-c", "core.quotepath=off", "-c", "status.renames=false",
                 "status", "--porcelain", "-z", "--untracked-files=all").decode("utf-8", "replace")
    changed = {}
    for ent in (e for e in status.split("\0") if e):
        changed[ent[3:]] = ent[:2]

    def disk(name):
        path = os.path.join(workdir, name)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()
        return "MISSING"

    for ent in sorted(e for e in staged.split("\0") if e):
        meta, name = ent.split("\t", 1)
        blob = meta.split()[1]
        h.update(b"T\0" + name.encode() + b"\0")
        h.update((disk(name) if name in changed else blob).encode())
    for name in sorted(changed):
        code = changed[name]
        if code == "??":
            base = os.path.basename(name)
            if name.startswith(HOST_DIRS) or base in HOST_FILES:
                continue
            if not name.endswith(UNTRACKED_SOURCE):
                continue
            h.update(b"U\0" + name.encode() + b"\0" + disk(name).encode())
        else:
            h.update(b"S\0" + code.encode() + name.encode() + b"\0")
    return h.hexdigest()


# ---- parsing and validation (data only) ------------------------------------

def parse_doc(text):
    """-> (doc, None) or (None, reason). Whitespace and ONE json fence tolerated."""
    s = text.strip()
    m = FENCE.match(s)
    if m:
        s = m.group(1).strip()
    try:
        return json.loads(s), None
    except ValueError as e:
        return None, "not JSON: %s" % e


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_defect(f):
    return f["class"] == "defect"


def validate(doc):
    """-> error string, or None when the document is valid."""
    if not isinstance(doc, dict):
        return "document is not an object"
    if set(doc) != set(KEYS_DOC):
        return "document keys %s" % sorted(doc)
    if doc["verdict"] not in VERDICTS:
        return "bad verdict"
    if not isinstance(doc["findings"], list):
        return "findings is not an array"
    for i, f in enumerate(doc["findings"]):
        if not isinstance(f, dict):
            return "finding %d is not an object" % i
        if set(f) != set(KEYS_FINDING):
            return "finding %d keys %s" % (i, sorted(f))
        if not isinstance(f["file"], str) or not isinstance(f["summary"], str):
            return "finding %d file/summary not a string" % i
        if not is_int(f["line_start"]) or not is_int(f["line_end"]):
            return "finding %d line not an integer" % i
        if f["line_start"] < 1 or f["line_end"] < f["line_start"]:
            return "finding %d bad line range" % i
        if f["class"] not in CLASSES or f["severity"] not in SEVERITIES:
            return "finding %d bad class/severity" % i
    return None


def verdict_consistent(doc):
    has = any(is_defect(f) for f in doc["findings"])
    return has == (doc["verdict"] == "defects_found")


# ---- judging -----------------------------------------------------------------

def norm_path(raw, workdir):
    """-> workdir-relative path of a regular file, or None."""
    p = raw
    root = os.path.realpath(workdir)
    if os.path.isabs(p):
        rp = os.path.realpath(p)
        if not rp.startswith(root + os.sep):
            return None
        p = os.path.relpath(rp, root)
    while p.startswith("./"):
        p = p[2:]
    real = os.path.realpath(os.path.join(root, p))
    if not real.startswith(root + os.sep) or not os.path.isfile(real):
        return None
    return p


def is_context(p):
    return p.startswith(".prod/") or p == "production.yaml"


def overlaps(f, lo, hi):
    return f["line_start"] <= hi and f["line_end"] >= lo


def judge(doc, workdir, kind, file=None, start=None, end=None):
    """Pure pass rules on a VALID document -> (ok_before_modification, metrics)."""
    m = blank(kind)
    code = []
    for f in doc["findings"]:
        p = norm_path(f["file"], workdir)
        if p is None:
            m["unknown_file_findings"] += 1
        elif is_context(p):
            m["context_findings"] += 1
        else:
            code.append(dict(f, file=p))
    m["non_defect_findings"] = sum(1 for f in code if not is_defect(f))
    m["nonspecific_findings"] = sum(
        1 for f in code if f["line_end"] - f["line_start"] + 1 > MAX_SPECIFIC_WIDTH)
    defects = [f for f in code if is_defect(f)]
    if kind == "clean":
        m["false_positives"] = len({(f["file"], f["line_start"]) for f in defects})
        return m["false_positives"] == 0, m
    lo, hi = start - SLACK, end + SLACK
    near = [f for f in defects if f["file"] == file and overlaps(f, lo, hi)]
    hits = [f for f in near if f["line_end"] - f["line_start"] + 1 <= MAX_SPECIFIC_WIDTH]
    m["found"] = 1 if hits else 0
    m["missed"] = 1 - m["found"]
    far = [f for f in defects if not (f["file"] == file and overlaps(f, lo, hi))]
    m["false_positives"] = len({(f["file"], f["line_start"]) for f in far})
    return m["found"] == 1 and m["false_positives"] <= MAX_FP_SEEDED, m


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--output")
    ap.add_argument("--expected")
    ap.add_argument("--file")
    ap.add_argument("--start", type=int)
    ap.add_argument("--end", type=int)
    ap.add_argument("--clean", action="store_true")
    ap.add_argument("--print-hash", action="store_true")
    a = ap.parse_args(argv)
    kind = "clean" if a.clean else "seeded"

    if not os.path.isdir(a.workdir):
        fail_error("workdir missing: %s" % a.workdir, kind)
    if a.print_hash:
        print(tree_hash(a.workdir))
        return
    if not a.output or not os.path.isfile(a.output):
        fail_error("agent output file missing", kind)
    if not a.expected or not os.path.isfile(a.expected):
        fail_error("expected.diffhash missing", kind)
    if not a.clean and (not a.file or a.start is None or a.end is None):
        fail_error("seeded task needs --file --start --end", kind)
    try:
        with open(a.expected) as f:
            expected = f.read().strip()
        modified = tree_hash(a.workdir) != expected
        with open(a.output, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except (OSError, subprocess.CalledProcessError) as e:
        fail_error(str(e), kind)

    doc, why = parse_doc(text)
    if why is not None:
        emit(blank(kind, modified_files=modified, parse_error=True))
        sys.exit(1)
    err = validate(doc)
    if err is None and not verdict_consistent(doc):
        err = "verdict contradicts the findings"
    if err is not None:
        emit(blank(kind, modified_files=modified, schema_error=True))
        sys.exit(1)

    ok, m = judge(doc, a.workdir, kind, a.file, a.start, a.end)
    m["modified_files"] = modified
    emit(m)
    sys.exit(0 if ok and not modified else 1)


if __name__ == "__main__":
    main()
