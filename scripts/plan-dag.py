#!/usr/bin/env python3
"""plan-dag.py -- turn a change plan into a verified DAG of waves.

Usage: python3 -I -B scripts/plan-dag.py PLAN [--format text|json]
                                         [--max-width N] [--landed id,id,...]
                                         [--strict-yaml]

WHY. `prod-spec` writes a change plan whose tasks carry `depends_on` and
`files`; an orchestrator dispatches together the tasks whose dependencies are
met and whose files are disjoint. Making that decision by reading the plan is
unreliable on graphs of 30+ nodes, so it is computed here, and a plan that
cannot be scheduled safely is refused with every problem named.

PLAN is either JSON ({"tasks":[{"id","depends_on":[..],"files":[..]}]}) or the
change-plan.yaml of prod-spec/references/change-plan.md.

WHAT IS VALIDATED, AND WHAT IS NOT. The YAML is read by a small STRICT subset
parser (no PyYAML needed). It validates ONLY the structure of the `tasks:`
section and the five fields it reads: `id`, `depends_on`, `files`, `kind`,
`estimate`. Everything else in the file (every other top-level key, every
other key of a task) is skipped UNREAD, so a plan can be invalid YAML there and
still be accepted. This tool does not validate YAML. `--strict-yaml` closes
that gap where PyYAML exists (see below).

THE TASKS PARSER REFUSES (exit 2, never guesses) every YAML shape it cannot
read exactly as a real YAML parser would: a second `tasks:` key (YAML keeps the
last); a duplicate `id`/`files`/`depends_on`/`kind`/`estimate` key in one task;
a block scalar (`|`, `>`) or a continuation line for one of those five; a
multi-line quoted scalar; an `id`, `files` entry or `depends_on` entry that is
not a plain or quoted STRING: a mapping (`- path: x`, an unquoted ': ' or a
trailing ':'), a nested list (`- - x`), a flow collection as an item (an
unquoted item starting with '{' or '[': quote it, a brace glob inside quotes
is a glob), an alias/anchor/tag/reserved indicator at the start of an
unquoted item (`*.go` unquoted is a YAML alias: quote globs); an unquoted
scalar YAML 1.1 would type as null/bool/int/float/timestamp (`~ null yes no on
off true false 1 0x10 1.5 1:30 2024-01-01 <<` ...: quote it); inside a
`[...]` list an unquoted item holding any of `? [ ] { }` or a ': '; list items
at different indents; a tab in an unquoted value; U+0085/U+2028/U+2029;
a `---` marker other than the first, any `...`. JSON plans may not repeat a key.

--strict-yaml: when PyYAML is importable, ALSO parse the whole file with
`yaml.safe_load`; exit 2 if that fails, or if PyYAML's (`id`, `depends_on`,
`files`) differ from this parser's for any task. Without PyYAML it exits 2
saying so. Use it wherever PyYAML exists (CI does).

CHECKS (exit 1, one line per problem, nothing printed as a plan):
  duplicate_id, missing_id, bad_field, unknown_dependency, cycle, no_files,
  bad_path, too_broad, file_conflict.
file_conflict = two tasks with NO dependency path between them (either way)
whose `files` MAY overlap: they could share a wave and collide on merge.
Limits (exit 2, "plan too large"): 1000 tasks, 2000 path entries after brace
expansion. The conflict check is O(n^2); the limits keep it to seconds.

--landed ID,ID: print only the READY set. Exit 2 unless every dependency
(transitively) of every landed task is itself listed, and unless the list has
no duplicate and no empty id (`--landed ""` alone means nothing landed).

OVERLAP RULE (conservative: when unsure, overlapping; the cost of an
over-report is one serialising depends_on, of an under-report a merge conflict)
  * a pattern is first brace-expanded in full (nested, with '/' inside braces
    allowed; `{a}` with no comma is read both as `a` and as the literal
    `{a}`); more than 256 expansions is too_broad, unbalanced braces bad_path;
    then every expansion of one is compared with every expansion of the other
    (a pair with more than 4096 combinations is reported as overlapping);
  * paths are compared case-insensitively, NFC-normalised, split on '/', '.'
    and '//' dropped; a trailing '/' means a directory and is read as '/**';
  * '**' (a whole component) matches zero or more components; other components
    overlap if both are literal and equal, literal vs glob by fnmatch, glob vs
    glob only if their literal prefixes are prefix-related AND their literal
    suffixes are suffix-related ('a/x*' vs 'a/y*' are disjoint, 'a*' vs '*b'
    overlap);
  * when one pattern is a proper path-prefix of the other (component-wise) they
    OVERLAP, always: a path cannot be both a file and a directory, so if both
    tasks are real one of them is wrong, and "may overlap" is the safe answer
    ('foo.d' vs 'foo.d/x', '.github' vs '.github/workflows/pr.yaml').
  Known over-reports: any two globs whose prefix/suffix test cannot separate
  them ('a/*b*' vs 'a/*c*'); case-differing names; a prefix pair as above.

Exit: 0 valid plan, 1 invalid plan, 2 usage / unreadable file / unparseable /
too large / --strict-yaml disagreement.
"""
import argparse
import fnmatch
import json
import re
import sys
import unicodedata

PROG = "plan-dag"
GLOBCH = "*?["
CODE_ORDER = ["missing_id", "duplicate_id", "bad_field", "unknown_dependency",
              "cycle", "no_files", "bad_path", "too_broad", "file_conflict"]
MAX_TASKS = 1000
MAX_PATHS = 2000
MAX_EXPANSIONS = 256
MAX_PAIR_PRODUCT = 4096
VIEW = ("id", "depends_on", "files")


class ParseError(Exception):
    pass


# --------------------------------------------------------------------------
# YAML subset (strict). Only the `tasks:` section is read.
# --------------------------------------------------------------------------
class Plain(str):
    """An UNQUOTED scalar: a real YAML parser would resolve its type."""


# PyYAML 6 (YAML 1.1) implicit resolvers, copied verbatim, matched whole-string.
_TYPED = [re.compile(x) for x in (
    r"yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF",
    r"[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?"
    r"|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?"
    r"|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*"
    r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)",
    r"[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)"
    r"|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+",
    r"<<", r"~|null|Null|NULL|", r"=",
    r"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
    r"|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)"
    r"[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?"
    r"(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?",
)]


def yaml_typed(s):
    """True if PyYAML would NOT read the unquoted scalar `s` as a string."""
    return any(r.fullmatch(s) for r in _TYPED)


def scan_line(s):
    """-> (text without a trailing comment, bracket depth delta, ends in a quote)."""
    q = None
    depth = 0
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if q:
            if q == '"' and ch == "\\":
                i += 2
                continue
            if ch == q:
                if q == "'" and s[i + 1:i + 2] == "'":
                    i += 2
                    continue
                q = None
        elif ch in "\"'":
            if i == 0 or s[i - 1] in " \t,[{:":
                q = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip(), depth, False
        i += 1
    return s.rstrip(), depth, q is not None


def strip_comment(s, strict=False, ln=0):
    text, _, inq = scan_line(s)
    if strict and inq:
        raise ParseError("line %d: a quoted scalar must open and close on one line "
                         "(multi-line quoted scalars are unsupported)" % ln)
    return text


_ESC = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "/": "/", "0": "\0", " ": " "}
QUOTE_HINT = "quote it ('...' or \"...\"); a glob must be quoted"


def check_block_plain(s, ln):
    """An unquoted value after `key:` or `- `."""
    if not s:
        raise ParseError("line %d: empty value or list item" % ln)
    c = s[0]
    if c in "&*!|>%@`":
        raise ParseError("line %d: %r at the start of an unquoted value is YAML "
                         "alias/anchor/tag/indicator syntax: %s" % (ln, c, QUOTE_HINT))
    if c in "[{":
        raise ParseError("line %d: an unquoted value starting with %r is YAML flow "
                         "syntax: %s" % (ln, c, QUOTE_HINT))
    if c in "-?:" and (len(s) == 1 or s[1] in " \t"):
        raise ParseError("line %d: %r starts a nested sequence/mapping, not a scalar" % (ln, c))
    if "\t" in s:
        raise ParseError("line %d: a tab inside an unquoted value" % ln)
    if ": " in s or s.endswith(":"):
        raise ParseError("line %d: an unquoted ': ' (or trailing ':') makes this a YAML "
                         "mapping, not a string: %s" % (ln, QUOTE_HINT))
    return Plain(s)


def check_flow_plain(s, ln):
    """An unquoted item inside `[...]` or `{...}`."""
    if not s:
        raise ParseError("line %d: empty item in a flow collection" % ln)
    if s[0] in "&*!|>%@`":
        raise ParseError("line %d: %r at the start of an unquoted item is YAML "
                         "alias/anchor/tag/indicator syntax: %s" % (ln, s[0], QUOTE_HINT))
    if s[0] == "-" and (len(s) == 1 or s[1] in " \t"):
        raise ParseError("line %d: '- ' starts a nested sequence" % ln)
    bad = [ch for ch in "?[]{}" if ch in s]
    if bad:
        raise ParseError("line %d: unquoted item %r holds %r, which YAML flow syntax "
                         "treats as structure: %s" % (ln, s, bad[0], QUOTE_HINT))
    if "\t" in s:
        raise ParseError("line %d: a tab inside an unquoted item" % ln)
    for k, ch in enumerate(s):
        if ch == ":" and (k == len(s) - 1 or s[k + 1] in " \t"):
            raise ParseError("line %d: an unquoted ': ' (or trailing ':') makes this a YAML "
                             "mapping: %s" % (ln, QUOTE_HINT))
    return Plain(s)


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
                if self.peek() and self.peek() in "\"'":
                    key = self.quoted()
                else:
                    key = self.plain(True, True)
                self.ws()
                if self.peek() != ":":
                    self.err("expected ':' in a flow mapping")
                self.i += 1
                if key in out:
                    self.err("duplicate key %r in a flow mapping" % key)
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
        if c and c in "\"'":
            return self.quoted()
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
        s = self.s[start:self.i].strip()
        if flow:
            return check_flow_plain(s, self.ln)
        return check_block_plain(s, self.ln)

    def done(self):
        self.ws()
        if self.i != len(self.s):
            self.err("unexpected text after the value: %r" % self.s[self.i:self.i + 20])


def parse_inline(text, lineno):
    """A whole value in block context (after `key:` or `- `)."""
    f = Flow(text, lineno)
    f.ws()
    c = f.peek()
    if c and (c in "[{" or c in "\"'"):
        v = f.value(False)
        f.done()
        return v
    return check_block_plain(text.strip(), lineno)


KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$")
WANTED = ("id", "kind", "files", "depends_on", "estimate")
SCALARISH = ("id", "files", "depends_on")


def check_read(key, v, ln, tid):
    """The three fields whose values the scheduler trusts: strings only."""
    if key not in SCALARISH or v is None:
        return v
    where = "line %d (task %s): `%s`" % (ln, tid, key)
    if key == "id":
        items = [v]
    elif isinstance(v, list):
        items = v
    else:
        items = [v]
    for it in items:
        if isinstance(it, (list, dict)):
            raise ParseError("%s holds a YAML %s where a string is required (an unquoted "
                             "item with ': ', a nested list, or an unquoted '{'/'[': %s)"
                             % (where, "mapping" if isinstance(it, dict) else "list", QUOTE_HINT))
        if isinstance(it, Plain) and yaml_typed(str(it)):
            raise ParseError("%s: unquoted %r would be read by YAML as a non-string "
                             "(null/bool/number/date): %s" % (where, str(it), QUOTE_HINT))
    return v


def join_flow(parts, ln):
    """Join the lines of one flow collection. A line break is only read as
    whitespace where it follows ',', '[' or '{' or precedes ',', ']' or '}'; a
    break inside an item would be folded or split by a real YAML parser."""
    out = parts[0]
    for nxt in parts[1:]:
        if not (out.rstrip()[-1:] in (",", "[", "{") or nxt.lstrip()[:1] in (",", "]", "}")):
            raise ParseError("line %d: a flow-collection item continues over a line "
                             "break; put each item on one line" % ln)
        out = out + " " + nxt
    return out


def _labels(entries):
    for key, inline, _, _ in entries:
        if key == "id" and inline:
            return strip_comment(inline).strip("\"'")
    return "?"


def parse_yaml_tasks(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    for ch in "\x85  ":
        if ch in text:
            raise ParseError("U+%04X is a YAML line break this parser does not model" % ord(ch))
    raw = text.split("\n")
    tlines = [n for n, line in enumerate(raw) if re.match(r"""^["']?tasks["']?[ \t]*:""", line)]
    if len(tlines) > 1:
        raise ParseError("`tasks:` appears %d times (lines %s); YAML keeps the LAST, this "
                         "parser would read the first: refused"
                         % (len(tlines), ",".join(str(n + 1) for n in tlines)))
    marks = [n for n, line in enumerate(raw) if re.match(r"^(---|\.\.\.)([ \t]|$)", line)]
    if len(marks) > 1 or any(raw[n].startswith("...") for n in marks):
        raise ParseError("YAML document markers ('...' or a second '---') are unsupported")
    start = None
    if tlines:
        line = raw[tlines[0]]
        if re.match(r"^tasks:[ \t]*(#.*)?$", line):
            start = tlines[0]
        elif re.match(r"^tasks:[ \t]*\[[ \t]*\][ \t]*(#.*)?$", line):
            return []
    if start is None:
        raise ParseError("no top-level `tasks:` section")
    L = []
    for n in range(start + 1, len(raw)):
        line = raw[n]
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
    return [parse_item(it) for it in items]


def _isdash(t):
    return t == "-" or t.startswith("- ")


def parse_item(lines):
    ln0, ind0, t0 = lines[0]
    rest = t0[1:].lstrip(" ")
    if not rest:
        raise ParseError("line %d: empty list item in `tasks:`" % ln0)
    if rest.startswith("{"):
        joined = join_flow([strip_comment(rest, True, ln0)]
                           + [strip_comment(t, True, ln) for ln, _, t in lines[1:]], ln0)
        f = Flow(joined, ln0)
        v = f.value(False)
        f.done()
        if not isinstance(v, dict):
            raise ParseError("line %d: task is not a mapping" % ln0)
        tid = v.get("id") if isinstance(v.get("id"), str) else "?"
        task = {}
        for k, val in v.items():
            if k in WANTED:
                task[k] = check_read(k, val, ln0, tid)
        return task
    keycol = ind0 + (len(t0) - len(rest))
    seq = [(ln0, keycol, rest)] + lines[1:]
    entries = []  # [key, inline, cont, ln]
    k = 0
    while k < len(seq):
        ln, ind, t = seq[k]
        k += 1
        if ind == keycol and not _isdash(t):
            m = KEY.match(strip_comment(t))
            if not m:
                raise ParseError("line %d: expected `key: value`" % ln)
            inline = (m.group(2) or "").strip()
            c0 = inline[:1]
            if c0 in ('"', "'"):
                inline = strip_comment(inline, True, ln)
            elif c0 in ("[", "{"):
                text, depth, inq = scan_line(inline)
                if inq:
                    raise ParseError("line %d: a quoted scalar must open and close on one line" % ln)
                parts = [text]
                while depth > 0:
                    if k >= len(seq):
                        raise ParseError("line %d: unterminated flow collection" % ln)
                    ln2, _, t2 = seq[k]
                    k += 1
                    text2, d2, inq2 = scan_line(t2)
                    if inq2:
                        raise ParseError("line %d: a quoted scalar must open and close on one line" % ln2)
                    parts.append(text2)
                    depth += d2
                inline = join_flow(parts, ln)
            else:
                inline = strip_comment(inline)
            entries.append([m.group(1), inline, [], ln])
        elif ind >= keycol:
            if not entries:
                raise ParseError("line %d: unexpected indentation" % ln)
            entries[-1][2].append((ln, ind, t))
        else:
            raise ParseError("line %d: unexpected indentation" % ln)
    tid = _labels(entries)
    task = {}
    seen = set()
    for key, inline, cont, ln in entries:
        if key not in WANTED:
            continue
        if key in seen:
            raise ParseError("line %d (task %s): duplicate key `%s` in one task; YAML keeps "
                             "the last, this parser would read the first: refused" % (ln, tid, key))
        seen.add(key)
        if not inline:
            if not cont:
                task[key] = None
                continue
            if not all(_isdash(t) for _, _, t in cont):
                raise ParseError("line %d (task %s): unsupported nested value for `%s`" % (ln, tid, key))
            if len({ind for _, ind, _ in cont}) != 1:
                raise ParseError("line %d (task %s): list items of `%s` at different indents "
                                 "(a deeper line continues the previous item in YAML)" % (ln, tid, key))
            vals = []
            for cl, _, t in cont:
                body = strip_comment(t[1:].strip(), True, cl)
                if not body or _isdash(body):
                    raise ParseError("line %d (task %s): empty or nested list item in `%s`" % (cl, tid, key))
                vals.append(parse_inline(body, cl))
            task[key] = check_read(key, vals, ln, tid)
        elif inline[0] in "|>":
            raise ParseError("line %d (task %s): a block scalar for `%s` is unsupported" % (ln, tid, key))
        else:
            if cont:
                raise ParseError("line %d (task %s): `%s` continues on the next line; put the "
                                 "value on ONE line (a real YAML parser folds it)" % (ln, tid, key))
            task[key] = check_read(key, parse_inline(inline, ln), ln, tid)
    return task


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------
def _no_dup(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ParseError("JSON key %r appears twice in one object" % k)
        d[k] = v
    return d


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ParseError("cannot read %s: %s" % (path, e.__class__.__name__))
    if "\0" in text:
        raise ParseError("not a text plan (NUL byte)")
    return text


def parse_plan(text, path):
    head = text.lstrip()
    if path.endswith(".json") or head.startswith("{") or head.startswith("["):
        try:
            doc = json.loads(text, object_pairs_hook=_no_dup)
        except (ValueError, RecursionError) as e:
            raise ParseError("not valid JSON: %s" % str(e).splitlines()[0][:80])
        if not isinstance(doc, dict) or not isinstance(doc.get("tasks"), list):
            raise ParseError('JSON plan must be {"tasks":[...]}')
        return doc["tasks"]
    return parse_yaml_tasks(text)


def load_plan(path):
    return parse_plan(read_text(path), path)


def _same(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return str(a) == str(b)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def strict_yaml_check(text, raw_tasks):
    """None when PyYAML agrees with this parser, else why not.
    Raises ParseError when PyYAML is not importable."""
    try:
        import yaml
    except ImportError:
        raise ParseError("--strict-yaml needs PyYAML and it is not importable here; this "
                         "parser's reading cannot be cross-checked")
    try:
        doc = yaml.safe_load(text)
    except Exception as e:
        return "PyYAML cannot load the file: %s" % str(e).replace("\n", " ")[:120]
    ytasks = doc.get("tasks") if isinstance(doc, dict) else None
    if not isinstance(ytasks, list):
        return "PyYAML sees no `tasks` list"
    if len(ytasks) != len(raw_tasks):
        return "PyYAML reads %d tasks, this parser %d" % (len(ytasks), len(raw_tasks))
    for n, (mine, theirs) in enumerate(zip(raw_tasks, ytasks), 1):
        if not isinstance(mine, dict) or not isinstance(theirs, dict):
            return "task #%d is not a mapping for both readers" % n
        for k in VIEW:
            if not _same(mine.get(k), theirs.get(k)):
                return "task #%d `%s`: this parser reads %r, PyYAML reads %r" % (
                    n, k, mine.get(k), theirs.get(k))
    return None


# --------------------------------------------------------------------------
# Paths and overlap
# --------------------------------------------------------------------------
class BraceError(ValueError):
    pass


class TooMany(Exception):
    pass


def expand_braces(s, cap=MAX_EXPANSIONS):
    """Full bash-style brace expansion (nested; '/' allowed inside). A group
    without a comma is returned both expanded and as the literal `{...}`."""
    i = s.find("{")
    k = s.find("}")
    if i < 0:
        if k >= 0:
            raise BraceError("unbalanced braces")
        return [s]
    if 0 <= k < i:
        raise BraceError("unbalanced braces")
    depth = 0
    commas = []
    j = -1
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
    alts = []
    last = i + 1
    for c in commas:
        alts.append(s[last:c])
        last = c + 1
    alts.append(s[last:j])
    inner = []
    for alt in alts:
        inner.extend(expand_braces(alt, cap))
        if len(inner) > cap:
            raise TooMany()
    if len(alts) == 1:
        inner = inner + ["{" + x + "}" for x in inner]
    sufs = expand_braces(s[j + 1:], cap)
    if len(inner) * len(sufs) > cap:
        raise TooMany()
    return [s[:i] + x + y for x in inner for y in sufs]


def _fold(c):
    n = unicodedata.normalize
    return n("NFC", n("NFC", c).casefold())


def norm_path(p):
    """Return (list of expansions, each a list of components, None) or (None, (code, why))."""
    if not isinstance(p, str) or not p.strip():
        return None, ("bad_path", "empty file path")
    if "\\" in p:
        return None, ("bad_path", "contains a backslash")
    try:
        exps = expand_braces(p)
    except BraceError:
        return None, ("bad_path", "unbalanced braces")
    except TooMany:
        return None, ("too_broad", "more than %d brace alternatives" % MAX_EXPANSIONS)
    out = []
    for e in exps:
        if e.startswith("/") or e.startswith("~") or re.match(r"^[A-Za-z]:", e):
            return None, ("bad_path", "absolute path")
        isdir = e.endswith("/")
        comps = [c for c in e.split("/") if c not in ("", ".")]
        if ".." in comps:
            return None, ("bad_path", "contains '..'")
        if not comps or all(c in ("*", "**") for c in comps):
            return None, ("too_broad", "would swallow the whole tree")
        comps = [_fold(c) for c in comps]
        comps = ["**" if c == "**" else re.sub(r"\*{2,}", "*", c) for c in comps]
        if isdir:
            comps.append("**")
        if comps not in out:
            out.append(comps)
    return out, None


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
        return fnmatch.fnmatchcase(lit, gl)
    pa, pb, sa, sb = pre(a), pre(b), suf(a), suf(b)
    return ((pa.startswith(pb) or pb.startswith(pa))
            and (sa.endswith(sb) or sb.endswith(sa)))


def overlap(p, q):
    """One expansion against one expansion (component lists)."""
    n, m = len(p), len(q)
    if p[0] != "**" and q[0] != "**" and not _comp_overlap(p[0], q[0]):
        return False
    # M[i][j]: suffixes p[i:], q[j:] may match a common path. When either side is
    # exhausted the other's rest is below the path the first one named: overlap.
    prev = None
    for i in range(n, -1, -1):
        row = [False] * (m + 1)
        for j in range(m, -1, -1):
            if i == n or j == m:
                v = True
            elif p[i] == "**":
                v = prev[j] or row[j + 1]
            elif q[j] == "**":
                v = row[j + 1] or prev[j]
            else:
                v = _comp_overlap(p[i], q[j]) and prev[j + 1]
            row[j] = v
        prev = row
    return prev[0]


def pair_overlap(ea, eb):
    """Lists of expansions; True if any pair may share a path."""
    if len(ea) * len(eb) > MAX_PAIR_PRODUCT:
        return True
    return any(overlap(x, y) for x in ea for y in eb)


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


def validate(raw_tasks):
    errors = []
    tasks = {}
    for n, t in enumerate(raw_tasks):
        if not isinstance(t, dict):
            errors.append(err("bad_field", [], None, "task #%d is not a mapping" % (n + 1)))
            continue
        tid = t.get("id")
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
        if not isinstance(deps, list) or not all(isinstance(d, str) for d in deps):
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
    entries = 0
    for tid in ids:
        comps[tid] = []
        for f in tasks[tid]["files"]:
            c, bad = norm_path(f)
            if bad:
                errors.append(err(bad[0], [tid], f if isinstance(f, str) else None,
                                  "%s: file %r: %s" % (tid, f, bad[1])))
            else:
                comps[tid].append((f, c))
                entries += len(c)
    if entries > MAX_PATHS:
        raise ParseError("plan too large: %d path entries after brace expansion (limit %d)"
                         % (entries, MAX_PATHS))
    cyc = find_cycle(tasks, ids)
    if cyc:
        errors.append(err("cycle", sorted(set(cyc)), None, "dependency cycle: " + " -> ".join(cyc)))
    anc = ancestors(tasks, ids)
    for ai in range(len(ids)):
        a = ids[ai]
        for bi in range(ai + 1, len(ids)):
            b = ids[bi]
            if b in anc[a] or a in anc[b]:
                continue
            hit = None
            for fa, ca in comps[a]:
                for fb, cb in comps[b]:
                    if pair_overlap(ca, cb):
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
        epilog="Validates ONLY the `tasks:` section's structure and its five fields "
               "(id, depends_on, files, kind, estimate); the rest of a YAML plan is "
               "skipped unread and may be invalid YAML (use --strict-yaml where PyYAML "
               "exists). Exit: 0 valid, 1 invalid plan, 2 usage/unreadable/unparseable/"
               "too large/--strict-yaml disagreement.")
    ap.add_argument("plan", help="change-plan.yaml (prod-spec format) or a JSON plan")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--max-width", type=int, default=None, metavar="N",
                    help="split any wave wider than N into sub-batches of at most N")
    ap.add_argument("--landed", default=None, metavar="ID,ID,...",
                    help="treat these tasks as done; print only the READY set. Must be "
                         "dependency-closed (every dependency of a landed task landed too), "
                         "no duplicates, no empty ids")
    ap.add_argument("--strict-yaml", action="store_true",
                    help="also parse the file with PyYAML safe_load and exit 2 if it fails "
                         "or reads id/depends_on/files differently; exit 2 if PyYAML is "
                         "not importable")
    a = ap.parse_args(argv)
    if a.max_width is not None and a.max_width < 1:
        print("%s: --max-width must be >= 1" % PROG, file=sys.stderr)
        return 2
    text = read_text(a.plan)
    raw = parse_plan(text, a.plan)
    if len(raw) > MAX_TASKS:
        raise ParseError("plan too large: %d tasks (limit %d)" % (len(raw), MAX_TASKS))
    if a.strict_yaml:
        why = strict_yaml_check(text, raw)
        if why:
            raise ParseError("--strict-yaml: " + why)
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
