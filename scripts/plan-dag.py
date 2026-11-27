#!/usr/bin/env python3
"""plan-dag.py -- turn a change plan into a verified DAG of waves.

Usage: python3 -I -B scripts/plan-dag.py PLAN [--format text|json]
                                         [--max-width N] [--landed id,id,...]

WHY. `prod-spec` writes a change plan whose tasks carry `depends_on` and
`files`; an orchestrator dispatches together the tasks whose dependencies are
met and whose files are disjoint. Making that decision by reading the plan is
unreliable on graphs of 30+ nodes, so it is computed here, and a plan that
cannot be scheduled safely is refused with every problem named.

PLAN is either JSON ({"tasks":[{"id","depends_on":[..],"files":[..]}]}) or the
change-plan.yaml of prod-spec/references/change-plan.md. The YAML is read by a
small STRICT subset parser (no PyYAML needed): it understands the `tasks:`
section as the plan format writes it (block items, flow-map items, quoted and
plain scalars, flow lists, block lists, comments, block scalars) and refuses
anything else with exit 2. Every other top-level key is ignored unread.

CHECKS (exit 1, one line per problem, nothing printed as a plan):
  duplicate_id, missing_id, bad_field, unknown_dependency, cycle, no_files,
  bad_path, too_broad, file_conflict.
file_conflict = two tasks with NO dependency path between them (either way)
whose `files` MAY overlap: they could share a wave and collide on merge.

OVERLAP RULE (conservative: when unsure, overlapping; the cost of an
over-report is one serialising depends_on, of an under-report a merge conflict)
  * paths are compared case-insensitively, split on '/', '.' and '//' dropped;
    a trailing '/' means a directory and is read as '/**';
  * '**' (a whole component) matches zero or more components;
  * two components overlap if both are literal and equal; literal vs glob by
    fnmatch (a glob with braces: literal-prefix and suffix test only); glob vs
    glob only if their literal prefixes are prefix-related AND their literal
    suffixes are suffix-related ('a/x*' vs 'a/y*' are disjoint, '*.md' vs '*.go'
    too, 'a*' vs '*b' overlap);
  * when one pattern ends before the other, they overlap if the shorter's last
    component has no '.' (it may name a directory) or the rest is only '**'.
  Known over-reports: 'src/**/*.go' vs 'src/a/Makefile' (extensionless last
  component read as a directory); any two globs whose prefix/suffix test cannot
  separate them ('a/*b*' vs 'a/*c*'); case-differing names.

Exit: 0 valid plan, 1 invalid plan, 2 usage / unreadable file / unparseable.
"""
import argparse
import fnmatch
import json
import re
import sys

PROG = "plan-dag"
GLOBCH = "*?[]{}"
CODE_ORDER = ["missing_id", "duplicate_id", "bad_field", "unknown_dependency",
              "cycle", "no_files", "bad_path", "too_broad", "file_conflict"]


class ParseError(Exception):
    pass


# --------------------------------------------------------------------------
# YAML subset (strict). Only the `tasks:` section is read.
# --------------------------------------------------------------------------
def strip_comment(s):
    q = None
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if q:
            if q == '"' and ch == "\\":
                i += 2
                continue
            if ch == q:
                q = None
        elif ch in "\"'":
            if i == 0 or s[i - 1] in " \t,[{:":
                q = ch
        elif ch == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
        i += 1
    return s.rstrip()


_ESC = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "/": "/", "0": "\0", " ": " "}


class Flow:
    def __init__(self, text, lineno):
        self.s = text
        self.i = 0
        self.ln = lineno

    def err(self, m):
        raise ParseError("line %d: %s" % (self.ln, m))

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def value(self, flow):
        self.ws()
        c = self.peek()
        if c == "[":
            self.i += 1
            out = []
            self.ws()
            if self.peek() == "]":
                self.i += 1
                return out
            while True:
                out.append(self.value(True))
                self.ws()
                c = self.peek()
                self.i += 1
                if c == ",":
                    self.ws()
                    if self.peek() == "]":
                        self.i += 1
                        return out
                    continue
                if c == "]":
                    return out
                self.err("expected ',' or ']'")
        if c == "{":
            self.i += 1
            out = {}
            self.ws()
            if self.peek() == "}":
                self.i += 1
                return out
            while True:
                self.ws()
                if self.peek() in "\"'":
                    key = self.quoted()
                else:
                    key = self.plain(True, True)
                self.ws()
                if self.peek() != ":":
                    self.err("expected ':' in a flow mapping")
                self.i += 1
                out[key] = self.value(True)
                self.ws()
                c = self.peek()
                self.i += 1
                if c == ",":
                    self.ws()
                    if self.peek() == "}":
                        self.i += 1
                        return out
                    continue
                if c == "}":
                    return out
                self.err("expected ',' or '}'")
        if c in "\"'":
            return self.quoted()
        if c and c in "&*!|>%@`":
            self.err("unsupported YAML construct %r" % c)
        return self.plain(flow, False)

    def quoted(self):
        q = self.s[self.i]
        self.i += 1
        out = []
        while self.i < len(self.s):
            ch = self.s[self.i]
            if q == '"' and ch == "\\":
                nxt = self.s[self.i + 1:self.i + 2]
                if nxt not in _ESC:
                    self.err("unsupported escape \\%s" % nxt)
                out.append(_ESC[nxt])
                self.i += 2
                continue
            if ch == q:
                if q == "'" and self.s[self.i + 1:self.i + 2] == "'":
                    out.append("'")
                    self.i += 2
                    continue
                self.i += 1
                return "".join(out)
            out.append(ch)
            self.i += 1
        self.err("unterminated quoted string")

    def plain(self, flow, key):
        start = self.i
        while self.i < len(self.s):
            ch = self.s[self.i]
            if flow and ch in ",]}":
                break
            if key and ch == ":" and self.s[self.i + 1:self.i + 2] in ("", " ", "\t"):
                break
            if key and ch == ":" and flow:
                break
            self.i += 1
        return self.s[start:self.i].strip()

    def done(self):
        self.ws()
        if self.i != len(self.s):
            self.err("unexpected text after the value: %r" % self.s[self.i:self.i + 20])


def parse_inline(text, lineno):
    """A whole value in block context (after `key:` or `- `)."""
    f = Flow(text, lineno)
    f.ws()
    c = f.peek()
    if c in ("[", "{") or c in "\"'":
        v = f.value(False)
        f.done()
        return v
    if c and c in "&*!%@`":
        f.err("unsupported YAML construct %r" % c)
    return text.strip()


KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$")
WANTED = ("id", "kind", "files", "depends_on", "estimate")


def parse_yaml_tasks(text):
    raw = text.split("\n")
    start = None
    for n, line in enumerate(raw):
        if re.match(r"^tasks:[ \t]*(#.*)?$", line):
            start = n
            break
        if re.match(r"^tasks:[ \t]*\[[ \t]*\][ \t]*(#.*)?$", line):
            return []
    if start is None:
        raise ParseError("no top-level `tasks:` section")
    L = []
    for n in range(start + 1, len(raw)):
        line = raw[n].rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        ind = len(line) - len(line.lstrip(" "))
        if line[ind:ind + 1] == "\t":
            raise ParseError("line %d: tab used for indentation" % (n + 1))
        if ind == 0 and not line.startswith("-"):
            break
        L.append((n + 1, ind, line[ind:]))
    if not L:
        raise ParseError("`tasks:` section is empty")
    base = L[0][1]
    items = []
    for ln, ind, t in L:
        if ind == base and (t == "-" or t.startswith("- ")):
            items.append([(ln, ind, t)])
        elif ind <= base:
            raise ParseError("line %d: unexpected line in `tasks:`" % ln)
        else:
            items[-1].append((ln, ind, t))
    tasks = []
    for it in items:
        tasks.append(parse_item(it))
    return tasks


def parse_item(lines):
    ln0, ind0, t0 = lines[0]
    rest = t0[1:].lstrip(" ")
    if not rest:
        raise ParseError("line %d: empty list item in `tasks:`" % ln0)
    if rest.startswith("{"):
        joined = " ".join([strip_comment(rest)] + [strip_comment(t) for _, _, t in lines[1:]])
        f = Flow(joined, ln0)
        v = f.value(False)
        f.done()
        if not isinstance(v, dict):
            raise ParseError("line %d: task is not a mapping" % ln0)
        return v
    keycol = ind0 + (len(t0) - len(rest))
    entries = []
    seq = [(ln0, keycol, rest)] + lines[1:]
    for ln, ind, t in seq:
        if ind == keycol and not (t == "-" or t.startswith("- ")):
            m = KEY.match(strip_comment(t))
            if not m:
                raise ParseError("line %d: expected `key: value`" % ln)
            entries.append([m.group(1), (m.group(2) or "").strip(), [], ln])
        elif ind >= keycol:
            if not entries:
                raise ParseError("line %d: unexpected indentation" % ln)
            entries[-1][2].append((ln, ind, t))
        else:
            raise ParseError("line %d: unexpected indentation" % ln)
    task = {}
    for key, inline, cont, ln in entries:
        if key not in WANTED:
            task.setdefault(key, None)
            continue
        if key in task and task[key] is not None:
            raise ParseError("line %d: duplicate key %s" % (ln, key))
        if not inline:
            if not cont:
                task[key] = None
            elif all(t == "-" or t.startswith("- ") for _, _, t in cont):
                vals = []
                for cl, _, t in cont:
                    body = strip_comment(t[1:].strip())
                    vals.append(parse_inline(body, cl))
                task[key] = vals
            else:
                raise ParseError("line %d: unsupported nested value for %s" % (ln, key))
        elif inline[0] in "|>":
            task[key] = ""
        else:
            body = strip_comment(inline)
            if body[:1] in ("[", "{", '"', "'"):
                body = " ".join([body] + [strip_comment(t) for _, _, t in cont])
            task[key] = parse_inline(body, ln)
    return task


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------
def load_plan(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ParseError("cannot read %s: %s" % (path, e.__class__.__name__))
    if "\0" in text:
        raise ParseError("not a text plan (NUL byte)")
    head = text.lstrip()
    if path.endswith(".json") or head.startswith("{") or head.startswith("["):
        try:
            doc = json.loads(text)
        except (ValueError, RecursionError) as e:
            raise ParseError("not valid JSON: %s" % str(e).splitlines()[0][:80])
        if not isinstance(doc, dict) or not isinstance(doc.get("tasks"), list):
            raise ParseError('JSON plan must be {"tasks":[...]}')
        return doc["tasks"]
    return parse_yaml_tasks(text)


# --------------------------------------------------------------------------
# Paths and overlap
# --------------------------------------------------------------------------
def norm_path(p):
    """Return (components, None) or (None, (code, why))."""
    if not isinstance(p, str) or not p.strip():
        return None, ("bad_path", "empty file path")
    if "\\" in p:
        return None, ("bad_path", "contains a backslash")
    if p.startswith("/") or p.startswith("~") or re.match(r"^[A-Za-z]:", p):
        return None, ("bad_path", "absolute path")
    isdir = p.endswith("/")
    comps = [c for c in p.split("/") if c not in ("", ".")]
    if ".." in comps:
        return None, ("bad_path", "contains '..'")
    if not comps or all(c in ("*", "**") for c in comps):
        return None, ("too_broad", "would swallow the whole tree")
    comps = [c.casefold() for c in comps]
    comps = ["**" if c == "**" else re.sub(r"\*{2,}", "*", c) for c in comps]
    if isdir:
        comps.append("**")
    return comps, None


def _isglob(c):
    return any(ch in c for ch in GLOBCH)


def _comp_overlap(a, b):
    ga, gb = _isglob(a), _isglob(b)
    if not ga and not gb:
        return a == b

    def pre(g):
        return g[:min(g.index(ch) for ch in GLOBCH if ch in g)]

    def suf(g):
        return g[max(g.rindex(ch) for ch in GLOBCH if ch in g) + 1:]
    if ga != gb:
        lit, gl = (b, a) if ga else (a, b)
        if "{" in gl or "}" in gl:
            return lit.startswith(pre(gl)) and lit.endswith(suf(gl))
        return fnmatch.fnmatchcase(lit, gl)
    pa, pb, sa, sb = pre(a), pre(b), suf(a), suf(b)
    return ((pa.startswith(pb) or pb.startswith(pa))
            and (sa.endswith(sb) or sb.endswith(sa)))


def overlap(p, q):
    n, m = len(p), len(q)
    p_dir = "." not in p[-1]
    q_dir = "." not in q[-1]
    # M[i][j]: suffixes p[i:], q[j:] may match a common path
    prev = None
    for i in range(n, -1, -1):
        row = [False] * (m + 1)
        for j in range(m, -1, -1):
            if i == n and j == m:
                v = True
            elif i == n:
                v = all(c == "**" for c in q[j:]) or p_dir
            elif j == m:
                v = all(c == "**" for c in p[i:]) or q_dir
            elif p[i] == "**":
                v = prev[j] or row[j + 1]
            elif q[j] == "**":
                v = row[j + 1] or prev[j]
            else:
                v = _comp_overlap(p[i], q[j]) and prev[j + 1]
            row[j] = v
        prev = row
    return prev[0]


# --------------------------------------------------------------------------
# Validation and scheduling
# --------------------------------------------------------------------------
def err(code, tasks, file, msg):
    return {"code": code, "tasks": list(tasks), "file": file, "msg": msg}


def validate(raw_tasks):
    errors = []
    tasks = {}
    for n, t in enumerate(raw_tasks):
        if not isinstance(t, dict):
            errors.append(err("bad_field", [], None, "task #%d is not a mapping" % (n + 1)))
            continue
        tid = t.get("id")
        if isinstance(tid, (int, float)) and not isinstance(tid, bool):
            tid = str(tid)
        if not isinstance(tid, str) or not tid.strip():
            errors.append(err("missing_id", [], None, "task #%d has no usable `id`" % (n + 1)))
            continue
        if tid in tasks:
            errors.append(err("duplicate_id", [tid], None, "task id %s is declared more than once" % tid))
            continue
        deps = t.get("depends_on")
        if deps is None:
            deps = []
        files = t.get("files")
        ok = True
        if not isinstance(deps, list) or not all(isinstance(d, (str, int)) and not isinstance(d, bool) for d in deps):
            errors.append(err("bad_field", [tid], None, "%s: depends_on must be a list of task ids" % tid))
            deps, ok = [], False
        if files is not None and (not isinstance(files, list) or not all(isinstance(f, str) for f in files)):
            errors.append(err("bad_field", [tid], None, "%s: files must be a list of paths" % tid))
            files, ok = [], False
        est = t.get("estimate")
        tasks[tid] = {"deps": sorted(set(str(d) for d in deps)), "files": files or [],
                      "bad": not ok, "estimate": est}
    ids = sorted(tasks)
    for tid in ids:
        info = tasks[tid]
        for d in info["deps"]:
            if d not in tasks:
                errors.append(err("unknown_dependency", [tid], None, "%s depends_on %s, which is not a task" % (tid, d)))
        if not info["files"] and not info["bad"]:
            errors.append(err("no_files", [tid], None,
                              "%s declares no files; a task without files cannot be checked for disjointness" % tid))
    comps = {}
    for tid in ids:
        comps[tid] = []
        for f in tasks[tid]["files"]:
            c, bad = norm_path(f)
            if bad:
                errors.append(err(bad[0], [tid], f if isinstance(f, str) else None,
                                  "%s: file %r: %s" % (tid, f, bad[1])))
            else:
                comps[tid].append((f, c))
    cyc = find_cycle(tasks, ids)
    if cyc:
        errors.append(err("cycle", sorted(set(cyc)), None, "dependency cycle: " + " -> ".join(cyc)))
    # ancestors (transitive depends_on), bounded BFS, safe on cycles
    anc = {}
    for tid in ids:
        seen = set()
        stack = [d for d in tasks[tid]["deps"] if d in tasks]
        while stack:
            x = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            stack.extend(d for d in tasks[x]["deps"] if d in tasks)
        anc[tid] = seen
    for ai in range(len(ids)):
        a = ids[ai]
        for bi in range(ai + 1, len(ids)):
            b = ids[bi]
            if b in anc[a] or a in anc[b]:
                continue
            hit = None
            for fa, ca in comps[a]:
                for fb, cb in comps[b]:
                    if overlap(ca, cb):
                        hit = (fa, fb)
                        break
                if hit:
                    break
            if hit:
                fa, fb = hit
                if fa == fb:
                    where, fld = "both touch %s" % fa, fa
                else:
                    where, fld = "%s may overlap %s" % (fa, fb), "%s ~ %s" % (fa, fb)
                errors.append(err(
                    "file_conflict", [a, b], fld,
                    "%s and %s have no dependency path between them and %s; "
                    "they could share a wave: add depends_on between them or split the files"
                    % (a, b, where)))
    errors.sort(key=lambda e: (CODE_ORDER.index(e["code"]), e["tasks"], e["file"] or "", e["msg"]))
    return tasks, errors


def find_cycle(tasks, ids):
    color = {}
    for root in ids:
        if root in color:
            continue
        path = [root]
        color[root] = 1
        its = [iter([d for d in tasks[root]["deps"] if d in tasks])]
        while its:
            adv = False
            for d in its[-1]:
                if color.get(d) == 1:
                    return path[path.index(d):] + [d]
                if d not in color:
                    color[d] = 1
                    path.append(d)
                    its.append(iter([x for x in tasks[d]["deps"] if x in tasks]))
                    adv = True
                    break
            if not adv:
                color[path.pop()] = 2
                its.pop()
    return None


def compute(tasks):
    ids = sorted(tasks)
    level = {}
    remaining = set(ids)
    waves = []
    while remaining:
        cur = sorted(t for t in remaining if all(d in level for d in tasks[t]["deps"]))
        if not cur:
            raise RuntimeError("scheduling stalled with %d tasks left" % len(remaining))
        for t in cur:
            level[t] = len(waves)
        remaining.difference_update(cur)
        waves.append(cur)
    dependants = {t: [] for t in ids}
    for t in ids:
        for d in tasks[t]["deps"]:
            dependants[d].append(t)
    # longest chain starting at t (by task count), ties -> lexicographically smallest
    down = {}
    for t in sorted(ids, key=lambda x: -level[x]):
        best = []
        for c in sorted(dependants[t]):
            if (-len(down[c]), down[c]) < (-len(best), best) or not best:
                best = down[c]
        down[t] = [t] + best
    cp = min((down[t] for t in ids), key=lambda p: (-len(p), p))
    verify_first = sorted(t for t in ids if dependants[t])
    est = None
    ests = [tasks[t]["estimate"] for t in ids]
    if ids and all(isinstance(e, (int, float)) and not isinstance(e, bool) and e >= 0 for e in ests):
        w = {}
        for t in sorted(ids, key=lambda x: -level[x]):
            tails = [w[c] for c in dependants[t]]
            if tails:
                bt = min(tails, key=lambda x: (-x[0], x[1]))
                w[t] = (tasks[t]["estimate"] + bt[0], (t,) + bt[1])
            else:
                w[t] = (tasks[t]["estimate"], (t,))
        top = min(w.values(), key=lambda x: (-x[0], x[1]))
        est = {"estimate_critical_path": list(top[1]), "estimate_critical_total": top[0]}
    return waves, cp, verify_first, est


def batches(ids, n):
    return [ids[i:i + n] for i in range(0, len(ids), n)] if ids else []


def main(argv):
    ap = argparse.ArgumentParser(
        prog=PROG, description="Verify a change plan and compute its waves.",
        epilog="Exit: 0 valid, 1 invalid plan, 2 usage/unreadable/unparseable.")
    ap.add_argument("plan", help="change-plan.yaml (prod-spec format) or a JSON plan")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--max-width", type=int, default=None, metavar="N",
                    help="split any wave wider than N into sub-batches of at most N")
    ap.add_argument("--landed", default=None, metavar="ID,ID,...",
                    help="treat these tasks as done; print only the READY set")
    a = ap.parse_args(argv)
    if a.max_width is not None and a.max_width < 1:
        print("%s: --max-width must be >= 1" % PROG, file=sys.stderr)
        return 2
    raw = load_plan(a.plan)
    tasks, errors = validate(raw)
    if not tasks and not errors:
        errors.append(err("no_tasks", [], None, "the plan has no tasks; nothing measured is not a pass"))
    if errors:
        if a.format == "json":
            print(json.dumps({"ok": False, "errors": errors}, separators=(",", ":")))
        else:
            for e in errors:
                print("ERROR %s: %s" % (e["code"], e["msg"]))
        return 1
    landed = set()
    if a.landed:
        landed = set(x for x in a.landed.split(",") if x)
        unknown = sorted(landed - set(tasks))
        if unknown:
            print("%s: --landed names unknown task(s): %s" % (PROG, ",".join(unknown)), file=sys.stderr)
            return 2
    waves, cp, vf, est = compute(tasks)
    ready = sorted(t for t in tasks if t not in landed and all(d in landed for d in tasks[t]["deps"]))
    width = max(len(w) for w in waves)
    if a.format == "json":
        out = {"ok": True, "waves": waves, "max_width": width, "critical_path": cp,
               "verify_first": vf, "ready": ready}
        if a.max_width:
            out["batches"] = [batches(w, a.max_width) for w in waves]
            out["ready_batches"] = batches(ready, a.max_width)
        if est:
            out.update(est)
        print(json.dumps(out, separators=(",", ":")))
        return 0
    vfs = set(vf)

    def tag(t):
        return t + (" [verify-first]" if t in vfs else "")
    if a.landed is not None:
        print("ready now (%d landed, width %d):" % (len(landed), len(ready)))
        if a.max_width:
            for k, b in enumerate(batches(ready, a.max_width), 1):
                print("  batch %d: %s" % (k, " ".join(tag(t) for t in b)))
        else:
            print("  " + " ".join(tag(t) for t in ready))
        return 0
    print("plan-dag: OK tasks=%d waves=%d max_width=%d" % (len(tasks), len(waves), width))
    for k, w in enumerate(waves, 1):
        print("wave %d (width %d): %s" % (k, len(w), " ".join(tag(t) for t in w)))
        if a.max_width and len(w) > a.max_width:
            for j, b in enumerate(batches(w, a.max_width), 1):
                print("  batch %d.%d: %s" % (k, j, " ".join(b)))
    print("critical path (%d): %s" % (len(cp), " -> ".join(cp)))
    if est:
        print("critical path by estimate (%s): %s" % (est["estimate_critical_total"],
                                                     " -> ".join(est["estimate_critical_path"])))
    print("verify-first (gates for dependants): %s" % (" ".join(vf) if vf else "none"))
    print("ready now: %s" % " ".join(ready))
    return 0


if __name__ == "__main__":
    try:
        rc = main(sys.argv[1:])
    except ParseError as e:
        print("%s: cannot parse plan: %s" % (PROG, e), file=sys.stderr)
        rc = 2
    except BrokenPipeError:
        rc = 2
    except Exception as e:  # never a traceback
        print("%s: internal error: %s: %s" % (PROG, e.__class__.__name__, str(e)[:100].replace("\n", " ")),
              file=sys.stderr)
        rc = 2
    sys.exit(rc)
