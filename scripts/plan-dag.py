#!/usr/bin/env python3
"""plan-dag.py -- turn a change plan into a verified DAG of waves.

Usage: python3 -I -B scripts/plan-dag.py PLAN [--format text|json]
                                         [--max-width N] [--landed id,id,...]
                                         [--strict-yaml]

WHY. `prod-spec` writes a change plan whose tasks carry `depends_on` and
`files`; an orchestrator starts together every task whose dependencies are met.
Two tasks that can touch the same path must never be started together, so the
plan is checked here and refused, with every problem named, if it cannot be
scheduled safely.

LOADING. No hand-written parser. A JSON plan (`.json`, or content starting with
`{`) is read by the stdlib `json` module; a YAML plan by PyYAML `safe_load`.
Both REJECT a duplicate mapping key at any depth; YAML also rejects a second
document. Without PyYAML a YAML plan is exit 2 ("PyYAML is required ..."), never
a fallback parser; JSON needs nothing. Invalid YAML ANYWHERE in the file is exit
2. The loaded structure is then type-checked: top level a mapping with a `tasks`
list of mappings; `id` a str (a YAML null/bool/int/float/date is bad_field:
quote it); `files` a list of str; `depends_on` absent, null or a list of str (a
scalar is bad_field); `estimate` absent, null or a finite number >= 0. Unknown
keys are ignored. --strict-yaml is accepted and does nothing: reading is always
strict.

CHECKS (exit 1, one line per problem, nothing printed as a plan):
  duplicate_id, missing_id, bad_field, unknown_dependency, cycle, no_files,
  bad_path, too_broad, file_conflict.
Limits (exit 2, "plan too large"): 1000 tasks, 2000 path entries after brace
expansion (checked while expanding, so a huge plan is refused at once); an
entry has at most 32 components. At most 50 lines of each error class are
printed, then "... and N more <class>" (JSON: `more` maps class -> count).
Task ids, dependency ids and file entries must be encodable as UTF-8 (a lone
surrogate is bad_field). Two ids equal after ASCII lower-casing + NFC are
bad_field: ids stay distinct, but a typo of that kind is never silent.

--landed ID,ID: print only the READY set. Exit 2 unless every dependency
(transitively) of every landed task is itself listed, and unless the list has
no duplicate and no empty id (`--landed ""` alone means nothing landed).

OVERLAP RULE (one rule, no glob algebra; it can over-report, never under-report)
  1. An entry is brace-expanded (simple comma form only, nested and '/' allowed,
     at most 256 expansions); `{1..3}`, unbalanced or empty braces are bad_path.
  2. Components are split on '/'; '.' and empty ones dropped; absolute, '~',
     drive letters, backslash, '..', control characters are bad_path.
  3. A component is LITERAL only if it is pure ASCII from the alphabet
     `A-Z a-z 0-9 . _ - + @ = , %` and does not end in '.'. Anything else (a
     wildcard, a non-ASCII letter, a space, `( ) | $ ! ^ #` ..., a trailing dot)
     is NON-literal: the LITERAL PREFIX is the leading run of literal components
     and stops before it, so such a component can never prove two entries apart.
     Filesystems disagree on case, normalisation and trailing dots, so only
     plain ASCII is ever compared.
  4. Two entries are DISJOINT only if, at some position where both have a literal
     component, the two differ after ASCII lower-casing. Everything else
     overlaps: equal entries, one prefix inside the other, a non-literal
     component reached first (`src/e-acute.go` overlaps `src/a.go`).
  5. An entry with an EMPTY literal prefix (`*.go`, `**/x`, a non-ASCII first
     component) is too_broad, unless the plan has exactly one task.
So `src/*.go` and `src/*.md` OVERLAP: list files explicitly or add depends_on.

Exit: 0 valid plan, 1 invalid plan, 2 usage / unreadable file / unparseable /
too large.
"""
import argparse
import json
import math
import re
import sys
import unicodedata

PROG = "plan-dag"
LITERAL = re.compile(r"[A-Za-z0-9._+@=,%-]+\Z")
CTRL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")
CODE_ORDER = ["missing_id", "duplicate_id", "bad_field", "unknown_dependency",
              "cycle", "no_files", "bad_path", "too_broad", "file_conflict"]
MAX_TASKS = 1000
MAX_PATHS = 2000
MAX_EXPANSIONS = 256
MAX_COMPONENTS = 32
MAX_LINES = 50
NO_YAML = ("PyYAML is required to read a YAML plan (pip install PyYAML), "
           "or pass the plan as JSON")


class ParseError(Exception):
    pass


# --------------------------------------------------------------------------
# Loading: stdlib json or PyYAML safe_load, duplicate keys refused
# --------------------------------------------------------------------------
def _no_dup(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ParseError("JSON key %r appears twice in one object" % k)
        d[k] = v
    return d


def _no_const(name):
    raise ParseError("JSON constant %s is not allowed" % name)


def load_yaml(text):
    try:
        import yaml
    except ImportError:
        raise ParseError(NO_YAML)

    class Loader(yaml.SafeLoader):
        pass

    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        seen = set()
        for knode, _ in node.value:
            k = self.construct_object(knode, deep=True)
            try:
                dup = k in seen
                seen.add(k)
            except TypeError:
                raise ParseError("a mapping key is not a scalar")
            if dup:
                raise ParseError("YAML key %r appears twice in one mapping" % (k,))
        return yaml.SafeLoader.construct_mapping(self, node, deep)

    Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)
    try:
        docs = list(yaml.load_all(text, Loader=Loader))
    except ParseError:
        raise
    except (yaml.YAMLError, RecursionError, ValueError, OverflowError) as e:
        raise ParseError("not valid YAML: %s" % str(e).replace("\n", " ")[:100])
    if len(docs) != 1:
        raise ParseError("a YAML plan is exactly one document (found %d)" % len(docs))
    return docs[0]


def load_plan(path, text=None):
    """The `tasks` list exactly as loaded; types are checked by validate()."""
    if text is None:
        text = read_text(path)
    head = text.lstrip()
    if path.endswith(".json") or head.startswith("{"):
        try:
            doc = json.loads(text, object_pairs_hook=_no_dup, parse_constant=_no_const)
        except (ValueError, RecursionError) as e:
            raise ParseError("not valid JSON: %s" % str(e).splitlines()[0][:80])
    else:
        doc = load_yaml(text)
    if not isinstance(doc, dict) or not isinstance(doc.get("tasks"), list):
        raise ParseError("a plan is a mapping with a `tasks` list")
    return doc["tasks"]


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ParseError("cannot read %s: %s" % (path, e.__class__.__name__))
    if "\0" in text:
        raise ParseError("not a text plan (NUL byte)")
    return text


# --------------------------------------------------------------------------
# Paths and overlap
# --------------------------------------------------------------------------
class BraceError(ValueError):
    pass


class TooMany(Exception):
    pass


def expand_braces(s, cap=MAX_EXPANSIONS):
    """Simple comma braces, nested, '/' allowed inside. A group with no comma
    stays literal (its braces remain, so its component is a wildcard)."""
    i = s.find("{")
    k = s.find("}")
    if i < 0:
        if k >= 0:
            raise BraceError("unbalanced braces")
        return [s]
    if 0 <= k < i:
        raise BraceError("unbalanced braces")
    depth, commas, j = 0, [], -1
    for idx in range(i, len(s)):
        ch = s[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                j = idx
                break
        elif ch == "," and depth == 1:
            commas.append(idx)
    if j < 0:
        raise BraceError("unbalanced braces")
    body = s[i + 1:j]
    if body == "":
        raise BraceError("empty brace group")
    if ".." in body:
        raise BraceError("brace sequence")
    cuts = [i] + commas + [j]
    alts = [s[cuts[n] + 1:cuts[n + 1]] for n in range(len(cuts) - 1)]
    inner = []
    for alt in alts:
        inner.extend(expand_braces(alt, cap))
        if len(inner) > cap:
            raise TooMany()
    if not commas:
        inner = ["{" + x + "}" for x in inner]
    sufs = expand_braces(s[j + 1:], cap)
    if len(inner) * len(sufs) > cap:
        raise TooMany()
    return [s[:i] + x + y for x in inner for y in sufs]


def _is_literal(c):
    """Pure ASCII from the safe alphabet, no trailing dot: the only components
    ever compared. ASCII lower-casing of such a component is exact."""
    return LITERAL.match(c) is not None and not c.endswith(".")


def _short(f):
    r = repr(f)
    return r if len(r) <= 120 else r[:117] + "..."


def _utf8(s):
    try:
        s.encode("utf-8")
        return True
    except UnicodeEncodeError:
        return False


def _id_key(s):
    return re.sub("[A-Z]", lambda m: m.group().lower(), unicodedata.normalize("NFC", s))


def norm_path(p):
    """([(literal_prefix, is_dir), ...], None) or (None, (code, why))."""
    if not isinstance(p, str) or not p.strip():
        return None, ("bad_path", "empty file path")
    if "\\" in p:
        return None, ("bad_path", "contains a backslash")
    if CTRL.search(p):
        return None, ("bad_path", "contains a control character")
    try:
        exps = expand_braces(p)
    except BraceError as e:
        return None, ("bad_path", "%s; write the paths out" % e)
    except TooMany:
        return None, ("too_broad", "more than %d brace alternatives" % MAX_EXPANSIONS)
    out, seen = [], set()
    for e in exps:
        if e.startswith("/") or e.startswith("~") or re.match(r"^[A-Za-z]:", e):
            return None, ("bad_path", "absolute path")
        comps = [c for c in e.split("/") if c not in ("", ".")]
        if ".." in comps:
            return None, ("bad_path", "contains '..'")
        if len(comps) > MAX_COMPONENTS:
            return None, ("bad_path", "more than %d components" % MAX_COMPONENTS)
        pre = []
        for c in comps:
            if not _is_literal(c):
                break
            pre.append(c.lower())
        ent = (tuple(pre), e.endswith("/"))
        if ent not in seen:
            seen.add(ent)
            out.append(ent)
    return out, None


def find_conflicts(entries):
    """entries: [(task, file_index, literal_prefix)] -> {(a, b): (ia, ib)}, a < b,
    for every pair of tasks owning two entries whose prefixes are equal or one
    inside the other (the only way two entries are not disjoint). Sorting the
    prefixes puts every extension of P right after P, so unrelated directories
    are never compared."""
    groups = {}
    for tid, fi, pre in entries:
        groups.setdefault(pre, []).append((tid, fi))
    keys = sorted(groups)
    hits = {}

    def add(xs, ys):
        for ta, fa in xs:
            for tb, fb in ys:
                if ta == tb:
                    continue
                k, v = ((ta, tb), (fa, fb)) if ta < tb else ((tb, ta), (fb, fa))
                if k not in hits or v < hits[k]:
                    hits[k] = v
    for i, pre in enumerate(keys):
        add(groups[pre], groups[pre])
        n = len(pre)
        j = i + 1
        while j < len(keys) and keys[j][:n] == pre:
            add(groups[pre], groups[keys[j]])
            j += 1
    return hits


# --------------------------------------------------------------------------
# Validation and scheduling
# --------------------------------------------------------------------------
def err(code, tasks, file, msg):
    return {"code": code, "tasks": list(tasks), "file": file, "msg": msg}


def ancestors(tasks, ids):
    """Transitive depends_on of every task, bounded BFS, safe on cycles."""
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
    return anc



def _is_num(e):
    return isinstance(e, (int, float)) and not isinstance(e, bool) and math.isfinite(e) and e >= 0


def validate(raw_tasks):
    """-> (tasks, errors, more) where more maps an error class to the lines not shown"""
    errors = []
    tasks = {}
    for n, t in enumerate(raw_tasks):
        if not isinstance(t, dict):
            errors.append(err("bad_field", [], None, "task #%d is not a mapping" % (n + 1)))
            continue
        if "id" not in t:
            errors.append(err("missing_id", [], None, "task #%d has no `id`" % (n + 1)))
            continue
        tid = t["id"]
        if not isinstance(tid, str):
            errors.append(err("bad_field", [], None,
                              "task #%d: `id` is %s, not a string; quote it" % (n + 1, type(tid).__name__)))
            continue
        if not _utf8(tid):
            errors.append(err("bad_field", [], None,
                              "task #%d: `id` is not valid UTF-8 text (lone surrogate)" % (n + 1)))
            continue
        if not tid.strip():
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
        if not isinstance(deps, list) or not all(isinstance(d, str) for d in deps):
            errors.append(err("bad_field", [tid], None, "%s: depends_on must be a list of task ids" % tid))
            deps, ok = [], False
        elif not all(_utf8(d) for d in deps):
            errors.append(err("bad_field", [tid], None, "%s: depends_on has text that is not valid UTF-8" % tid))
            deps, ok = [], False
        if files is not None and (not isinstance(files, list) or not all(isinstance(f, str) for f in files)):
            errors.append(err("bad_field", [tid], None, "%s: files must be a list of paths" % tid))
            files, ok = [], False
        elif files is not None and not all(_utf8(f) for f in files):
            errors.append(err("bad_field", [tid], None, "%s: files has text that is not valid UTF-8" % tid))
            files, ok = [], False
        est = t.get("estimate")
        if est is not None and not _is_num(est):
            errors.append(err("bad_field", [tid], None, "%s: estimate must be a number >= 0" % tid))
            est, ok = None, False
        tasks[tid] = {"deps": sorted(set(deps)), "files": files or [],
                      "bad": not ok, "estimate": est}
    ids = sorted(tasks)
    keyed = {}
    for tid in ids:
        keyed.setdefault(_id_key(tid), []).append(tid)
    for grp in sorted(keyed.values()):
        if len(grp) > 1:
            errors.append(err("bad_field", grp, None,
                              "ids differ only by case or normalisation: %s"
                              % ", ".join(repr(g) for g in grp)))
    for tid in ids:
        info = tasks[tid]
        for d in info["deps"]:
            if d not in tasks:
                errors.append(err("unknown_dependency", [tid], None, "%s depends_on %s, which is not a task" % (tid, _short(d))))
        if not info["files"] and not info["bad"]:
            errors.append(err("no_files", [tid], None,
                              "%s declares no files; a task without files cannot be checked for disjointness" % tid))
    entries = []
    npaths = 0
    for tid in ids:
        for fi, f in enumerate(tasks[tid]["files"]):
            c, bad = norm_path(f)
            if bad:
                errors.append(err(bad[0], [tid], f, "%s: file %s: %s" % (tid, _short(f), bad[1])))
                continue
            for pre, _isdir in c:
                npaths += 1
                if npaths > MAX_PATHS:
                    raise ParseError("plan too large: more than %d path entries after brace expansion"
                                     % MAX_PATHS)
                if not pre:
                    if len(raw_tasks) != 1:
                        errors.append(err("too_broad", [tid], f,
                                          "%s: file %s starts with a wildcard or a non-literal component, so it "
                                          "overlaps every other task; name a literal ASCII directory first"
                                          % (tid, _short(f))))
                    continue
                entries.append((tid, fi, pre))
    cyc = find_cycle(tasks, ids)
    if cyc:
        errors.append(err("cycle", sorted(set(cyc)), None, "dependency cycle: " + " -> ".join(cyc)))
    errors.sort(key=lambda e: (CODE_ORDER.index(e["code"]), e["tasks"], e["file"] or "", e["msg"]))
    more, shown = {}, {}
    kept = []
    for e in errors:
        shown[e["code"]] = shown.get(e["code"], 0) + 1
        if shown[e["code"]] <= MAX_LINES:
            kept.append(e)
        else:
            more[e["code"]] = more.get(e["code"], 0) + 1
    errors = kept
    anc = ancestors(tasks, ids)
    hits = find_conflicts(entries)
    pairs = sorted(k for k in hits if k[1] not in anc[k[0]] and k[0] not in anc[k[1]])
    for a, b in pairs[:MAX_LINES]:
        fa, fb = (tasks[a]["files"][hits[(a, b)][0]], tasks[b]["files"][hits[(a, b)][1]])
        if fa == fb:
            where, fld = "both touch %s" % fa, fa
        else:
            where, fld = "%s may overlap %s" % (fa, fb), "%s ~ %s" % (fa, fb)
        errors.append(err(
            "file_conflict", [a, b], fld,
            "%s and %s have no dependency path between them and %s; "
            "they could share a wave: add depends_on between them or split the files"
            % (a, b, where)))
    if len(pairs) > MAX_LINES:
        more["file_conflict"] = len(pairs) - MAX_LINES
    return tasks, errors, more


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


OVERLAP_HELP = """Overlap rule: braces expand (simple comma form, max 256). A path component is
literal only if it is pure ASCII from A-Z a-z 0-9 . _ - + @ = , % and does
not end in '.'; any other component (wildcard, non-ASCII, space, ( ) | $ !,
trailing dot) is non-literal and ends the entry's literal prefix, so it never
proves two entries apart (src/e-acute.go overlaps src/a.go). Two entries are
disjoint only if both have a literal component at some position and the two
differ after ASCII lower-casing; otherwise they overlap. An entry whose first
component is non-literal (*.go, **/x, a non-ASCII name) is too_broad unless the
plan has one task. So src/*.go and src/*.md overlap:
list files explicitly or add depends_on."""


def main(argv):
    ap = argparse.ArgumentParser(
        prog=PROG, description="Verify a change plan and compute its waves.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=OVERLAP_HELP + "\nExit: 0 valid, 1 invalid plan, 2 usage/unreadable/"
               "unparseable/too large. A YAML plan needs PyYAML (else pass JSON).")
    ap.add_argument("plan", help="change-plan.yaml (prod-spec format) or a JSON plan")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--max-width", type=int, default=None, metavar="N",
                    help="split any wave wider than N into sub-batches of at most N")
    ap.add_argument("--landed", default=None, metavar="ID,ID,...",
                    help="treat these tasks as done; print only the READY set. Must be "
                         "dependency-closed (every dependency of a landed task landed too), "
                         "no duplicates, no empty ids")
    ap.add_argument("--strict-yaml", action="store_true",
                    help="accepted for compatibility and ignored: reading is always strict")
    a = ap.parse_args(argv)
    if a.max_width is not None and a.max_width < 1:
        print("%s: --max-width must be >= 1" % PROG, file=sys.stderr)
        return 2
    raw = load_plan(a.plan)
    if len(raw) > MAX_TASKS:
        raise ParseError("plan too large: %d tasks (limit %d)" % (len(raw), MAX_TASKS))
    tasks, errors, more = validate(raw)
    if not tasks and not errors:
        errors.append(err("no_tasks", [], None, "the plan has no tasks; nothing measured is not a pass"))
    if errors:
        if a.format == "json":
            doc = {"ok": False, "errors": errors}
            if more:
                doc["more"] = more
            if more.get("file_conflict"):
                doc["more_file_conflicts"] = more["file_conflict"]
            print(json.dumps(doc, separators=(",", ":")))
        else:
            last = None
            for e in errors + [None]:
                code = e["code"] if e else None
                if last is not None and code != last and more.get(last):
                    print("... and %d more %s" % (more[last], last))
                if e:
                    print("ERROR %s: %s" % (code, e["msg"]))
                last = code
        return 1
    landed = set()
    if a.landed:
        lids = a.landed.split(",")
        if any(x == "" for x in lids):
            print("%s: --landed has an empty id" % PROG, file=sys.stderr)
            return 2
        dups = sorted(set(x for x in lids if lids.count(x) > 1))
        if dups:
            print("%s: --landed lists %s more than once" % (PROG, ",".join(dups)), file=sys.stderr)
            return 2
        landed = set(lids)
        unknown = sorted(landed - set(tasks))
        if unknown:
            print("%s: --landed names unknown task(s): %s" % (PROG, ",".join(unknown)), file=sys.stderr)
            return 2
        anc = ancestors(tasks, sorted(tasks))
        for x in sorted(landed):
            missing = sorted(anc[x] - landed)
            if missing:
                print("%s: --landed lists %s but not its dependency %s (landed must be "
                      "dependency-closed)" % (PROG, x, missing[0]), file=sys.stderr)
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


def cli(argv):
    for st in (sys.stdout, sys.stderr):  # output must never raise on odd text
        try:
            st.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    try:
        return main(argv)
    except ParseError as e:
        print("%s: cannot parse plan: %s" % (PROG, e), file=sys.stderr)
        return 2
    except BrokenPipeError:
        return 2
    except Exception as e:  # never a traceback
        print("%s: internal error: %s: %s" % (PROG, e.__class__.__name__, str(e)[:100].replace("\n", " ")),
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
