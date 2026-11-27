#!/usr/bin/env python3
"""assemble.py -- build a repo tree from prod-new modules.

Usage:
  python3 -I -B scripts/assemble.py --dest DIR --layout single|monorepo \
      --module ID [--module ID ...] --slot NAME=VALUE [--slot ...] \
      [--modules-dir DIR] [--strict-tracked]

A module is prod-new/modules/<id>/module.json: `source` (relative to the module
dir), `slots`, and `placement` (ordered glob -> "root" | "unit", first match
wins). Every source file must match a glob (no catch-all, so a dropped glob is
an error, not a silent relocation). Layout `single`: root and unit are the repo
root. Layout `monorepo`: unit is services/<SERVICE>, and a module that places
anything as `unit` must declare (and be given) the SERVICE slot, else exit 2.

SLOT VALUES. ONE grammar for every value, checked before anything else:
  [A-Za-z0-9][A-Za-z0-9._-]*   (full match: no `/` `\\` `&` `<` whitespace NUL
  newline, no leading `-` or `.`, never `.` or `..`, ASCII only)
instantiate-template.sh enforces the same regex, so both tools accept and
refuse exactly the same values. A slot may NARROW it with a `pattern` (a regex,
full match, applied in addition); the grammar can never be widened. Because a
value cannot contain `<`, a substituted value is never a placeholder; and
substitution is ONE pass over all placeholders (longest first), so a value is
never re-scanned and the result does not depend on --slot order.

Slots are literal token replacement of <NAME> in contents (bytes) and in paths,
as instantiate-template.sh does. A literal slot ({"literal": L}, L at least 3
chars) replaces L itself, but only where L is not adjacent to [A-Za-z0-9_] on
the sides where L starts/ends with such a character: `@acme/pkg` and `acme/x`
hit, `acmes` and `xacme` do not (a `-` or `.` neighbour counts as a boundary).

SAFETY. Every final path is checked twice: the value grammar, and independently
`escapes()` (relative, no empty/`.`/`..` component, resolves under the real
dest). The whole tree is PLANNED first (no write until every check passed), then
written into a fresh temp dir created next to dest and renamed into place only
on full success; on any failure the temp dir is removed and dest is untouched.
Plan refusals: a file/link planned at a path that is also a proper prefix of
another entry (file vs dir, link redirect); a link whose target is absolute or
leaves the module's source tree. Symlinks inside a module are copied AS links
(like `cp -R`), never followed; writes use O_EXCL|O_NOFOLLOW. The template
ships no links today.

DEST CONTRACT: dest must not exist, or be an empty directory (it is replaced by
the finished tree via rename; its own mode is not kept). A symlink dest is
refused. Missing parent dirs are created only after success.

Exit: 0 ok - 1 refused input (leftover slot, unplaced file, dest not empty or a
link, path escape, collision, conflict, requires/conflicts, unused literal,
I/O failure) - 2 usage or manifest error (bad --slot, bad value, bad manifest).
Every refusal is ONE message on stderr (plus listed items); never a traceback.

MANIFEST KEYS (MANIFEST_KEYS below is the one list; unknown key -> exit 2):
  id            required; ^[a-z][a-z0-9-]*$ and equal to the directory name.
  source        required; relative path from the module dir. `..` is allowed
                only because service-go's source is ../../template: the real
                path must lie inside the modules dir's parent (prod-new/).
  placement     required; {glob: "root"|"unit"}.
  requires      [module ids] each must also be selected, else exit 1.
  conflicts     [module ids] none may also be selected, else exit 1.
  unit_kind     optional string (informational).
  exclude       [globs] never placed, never reported unplaced. When `source` is
                the module dir itself, module.json at its root is always excluded.
  root_merge    {glob: "union-lines"} destinations that may be merged when two
                modules place different bytes there: the later module's lines
                that are not already present are appended; lines are never
                de-duplicated within one file. Contributors must agree on mode
                and on LF vs CRLF, and each must end with a newline, else an
                error (nothing is normalised). Every contributor declares the glob.
  strict_slots  true: any leftover <[A-Z][A-Z0-9_]*> token in file CONTENTS is a
                refusal (paths are always checked), unless listed in slot_allow.
  slot_allow    [tokens] names (without <>) tolerated by strict_slots.
  slots         NAME -> description string or {"description", "literal",
                "pattern"}. A literal that never occurs is an error.

CANDIDATE FILES. Inside a git work tree: `git ls-files --cached --others
--exclude-per-directory=.gitignore` restricted to the source dir, with user and
system git config neutralised (GIT_* stripped from the environment,
GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1, -c core.excludesFile=) and
.git/info/exclude not consulted. So these ship: every TRACKED file (working-tree
version; tracked-but-deleted is skipped) and every UNTRACKED file that no
.gitignore in the tree ignores. An untracked stray therefore ships; that breaks
byte parity with instantiate-template.sh, so `--strict-tracked` refuses when any
untracked-not-ignored file exists in a source dir (and outside git, where
"tracked" is undefined). It is not the default because a module under
development is legitimately untracked; the parity selftest uses it. Outside git:
a filesystem walk. Two modules placing the same destination is allowed only when
kind, bytes and mode are identical after substitution, or root_merge applies.
"""
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

VALUE_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
SLOT_NAME_RX = re.compile(r"[A-Z][A-Z0-9_]*")
MODULE_ID_RX = re.compile(r"[a-z][a-z0-9-]*")
MANIFEST_KEYS = ("id", "source", "placement", "requires", "conflicts", "unit_kind",
                 "exclude", "root_merge", "strict_slots", "slot_allow", "slots")
SLOT_KEYS = ("description", "literal", "pattern")
LAYOUTS = ("single", "monorepo")
STRATEGIES = ("union-lines",)
TOKEN = re.compile(rb"<([A-Z][A-Z0-9_]*)>")
WORD = re.compile(r"[A-Za-z0-9_]")


def die(code, msg):
    sys.stderr.write("assemble: " + msg + "\n")
    sys.exit(code)


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile(out + r"\Z")


def check_value(name, v):
    """The value grammar. Same regex as instantiate-template.sh."""
    if VALUE_RX.fullmatch(v) is None:
        die(2, "slot %s: value %r is outside the value grammar "
            "[A-Za-z0-9][A-Za-z0-9._-]*" % (name, v))


def escapes(root, rel):
    """True when root/rel would leave root: absolute, NUL, an empty/./.. component, or a
    parent directory that resolves outside the real root. Independent of check_value."""
    if "\0" in rel or rel.startswith("/") or any(c in ("", ".", "..") for c in rel.split("/")):
        return True
    real_root = os.path.realpath(root)
    parent = os.path.realpath(os.path.dirname(os.path.join(root, rel)))
    return not (parent == real_root or parent.startswith(real_root + os.sep))


class Subst:
    """One pass over every placeholder of a module, longest first; values are never
    re-scanned. Literal placeholders respect word boundaries; hits records used slots."""

    def __init__(self, ph, vals, lits):
        self.hits = set()
        self.by_text = {p: k for k, p in ph.items()}
        self.vals = vals
        parts = []
        for k, p in sorted(ph.items(), key=lambda kv: (-len(kv[1]), kv[1])):
            e = re.escape(p)
            if k in lits:
                if WORD.match(p[0]):
                    e = "(?<![A-Za-z0-9_])" + e
                if WORD.match(p[-1]):
                    e += "(?![A-Za-z0-9_])"
            parts.append(e)
        self.rx_s = re.compile("|".join(parts)) if parts else None
        self.rx_b = re.compile("|".join(parts).encode()) if parts else None

    def _s(self, m):
        k = self.by_text[m.group(0)]
        self.hits.add(k)
        return self.vals[k]

    def _b(self, m):
        k = self.by_text[m.group(0).decode()]
        self.hits.add(k)
        return self.vals[k].encode()

    def s(self, text):
        return self.rx_s.sub(self._s, text) if self.rx_s else text

    def b(self, data):
        return self.rx_b.sub(self._b, data) if self.rx_b else data


def split_lines(d):
    if not d:
        return None, []
    crlf, lf = d.count(b"\r\n"), d.count(b"\n")
    if crlf and crlf != lf:
        raise ValueError("a file mixes CRLF and LF line endings")
    eol = b"\r\n" if crlf else b"\n"
    if not d.endswith(eol):
        raise ValueError("a file has no trailing newline")
    return eol, d[:-len(eol)].split(eol)


def union_lines(a, b):
    """a, then the lines of b that a does not already contain. Nothing is normalised."""
    ea, la = split_lines(a)
    eb, lb = split_lines(b)
    if ea and eb and ea != eb:
        raise ValueError("contributors use different line endings (CRLF vs LF)")
    present = set(la)
    out = la + [x for x in lb if x not in present]
    eol = ea or eb or b"\n"
    return eol.join(out) + eol if out else b""


def git_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def git_list(src, env, others_only):
    flags = ["--others"] if others_only else ["--cached", "--others"]
    r = subprocess.run(["git", "-c", "core.excludesFile=", "-C", src, "ls-files", "-z"] + flags +
                       ["--exclude-per-directory=.gitignore", "--", "."], capture_output=True, env=env)
    if r.returncode != 0:
        die(1, "git ls-files failed in %s" % src)
    return [os.fsdecode(b) for b in r.stdout.split(b"\0") if b]


def candidates(src, strict):
    """Relative paths of files (and symlinks) under src, sorted."""
    env = git_env()
    try:
        r = subprocess.run(["git", "-C", src, "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, env=env)
        inside = r.returncode == 0 and r.stdout.strip() == b"true"
    except OSError:
        inside = False
    if strict:
        if not inside:
            die(1, "--strict-tracked: %s is not inside a git work tree" % src)
        stray = git_list(src, env, True)
        if stray:
            die(1, "--strict-tracked: %d untracked file(s) in %s would ship, e.g. %s"
                % (len(stray), src, ", ".join(sorted(stray)[:5])))
    if inside:
        out = set()
        for rel in git_list(src, env, False):
            full = os.path.join(src, rel)
            if not os.path.lexists(full) or (os.path.isdir(full) and not os.path.islink(full)):
                continue  # tracked but deleted, or a submodule
            out.add(rel)
        return sorted(out)
    entries = []
    for dp, dns, fns in os.walk(src):
        dns.sort()
        for n in sorted(fns) + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            entries.append(os.path.relpath(os.path.join(dp, n), src))
    return sorted(entries)


def load_manifest(mid, mdir):
    mp = os.path.join(mdir, mid, "module.json")
    if not MODULE_ID_RX.fullmatch(mid) or not os.path.isfile(mp):
        die(2, "unknown module %r (no %s)" % (mid, mp))

    def bad(msg):
        die(2, "module %s: %s" % (mid, msg))

    try:
        with open(mp, encoding="utf-8") as f:
            m = json.load(f)
    except (ValueError, RecursionError, OSError) as e:
        die(2, "unreadable manifest %s: %s" % (mp, e))
    if not isinstance(m, dict):
        bad("manifest must be a JSON object")
    unknown = sorted(set(m) - set(MANIFEST_KEYS))
    if unknown:
        bad("unknown key(s) %s (allowed: %s)" % (", ".join(unknown), ", ".join(MANIFEST_KEYS)))
    for key in ("id", "source", "placement"):
        if key not in m:
            bad("missing required key %r" % key)
    if m["id"] != mid:
        bad("key 'id' is %r but the module directory is %r" % (m["id"], mid))
    if not isinstance(m["source"], str) or not m["source"] or "\0" in m["source"] \
            or os.path.isabs(m["source"]):
        bad("key 'source' must be a non-empty relative path string")
    if not isinstance(m["placement"], dict) or not all(
            isinstance(g, str) and g and isinstance(t, str) for g, t in m["placement"].items()):
        bad("key 'placement' must be an object of glob -> \"root\"|\"unit\"")
    for g, t in m["placement"].items():
        if t not in ("root", "unit"):
            bad("placement %r -> %r (want root|unit)" % (g, t))
    for key in ("exclude", "slot_allow", "requires", "conflicts"):
        v = m.get(key, [])
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            bad("key %r must be a list of strings" % key)
    for key in ("requires", "conflicts"):
        for x in m.get(key, []):
            if not MODULE_ID_RX.fullmatch(x):
                bad("key %r: %r is not a module id" % (key, x))
    if "strict_slots" in m and not isinstance(m["strict_slots"], bool):
        bad("key 'strict_slots' must be true or false")
    if "unit_kind" in m and not isinstance(m["unit_kind"], str):
        bad("key 'unit_kind' must be a string")
    rm = m.get("root_merge", {})
    if not isinstance(rm, dict):
        bad("key 'root_merge' must be an object")
    for g, strat in rm.items():
        if strat not in STRATEGIES:
            bad("root_merge %r -> %r (known: %s)" % (g, strat, ", ".join(STRATEGIES)))
    mslots = m.get("slots", {})
    if not isinstance(mslots, dict):
        bad("key 'slots' must be an object")
    m["_ph"], m["_lit"], m["_pat"] = {}, {}, {}
    for k, v in mslots.items():
        if not SLOT_NAME_RX.fullmatch(k):
            bad("slot name %r must match [A-Z][A-Z0-9_]*" % k)
        if isinstance(v, str):
            continue
        if not isinstance(v, dict):
            bad("slot %s must be a description string or an object" % k)
        extra = sorted(set(v) - set(SLOT_KEYS))
        if extra:
            bad("slot %s: unknown key(s) %s (allowed: %s)" % (k, ", ".join(extra), ", ".join(SLOT_KEYS)))
        if "description" in v and not isinstance(v["description"], str):
            bad("slot %s: description must be a string" % k)
        if "literal" in v:
            if not isinstance(v["literal"], str) or len(v["literal"]) < 3:
                bad("slot %s: literal must be a string of at least 3 characters" % k)
            m["_ph"][k] = m["_lit"][k] = v["literal"]
        if "pattern" in v:
            try:
                if not isinstance(v["pattern"], str):
                    raise re.error("not a string")
                m["_pat"][k] = re.compile(v["pattern"])
            except re.error as e:
                bad("slot %s: pattern is not a valid regex (%s)" % (k, e))
    return m


def run():
    ap = argparse.ArgumentParser(add_help=True, allow_abbrev=False)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--module", action="append", default=[])
    ap.add_argument("--slot", action="append", default=[])
    ap.add_argument("--modules-dir", default=None)
    ap.add_argument("--strict-tracked", action="store_true")
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(2 if e.code else 0)

    if a.layout not in LAYOUTS:
        die(2, "unknown layout %r (known: %s)" % (a.layout, ", ".join(LAYOUTS)))
    if not a.module:
        die(2, "no --module given")
    if len(set(a.module)) != len(a.module):
        die(2, "a --module is given twice")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mdir = a.modules_dir or os.path.join(root, "prod-new", "modules")

    slots = {}
    for s in a.slot:
        k, sep, v = s.partition("=")
        if not sep or not k:
            die(2, "bad --slot %r (want NAME=VALUE)" % s)
        if not SLOT_NAME_RX.fullmatch(k):
            die(2, "bad --slot name %r (want [A-Z][A-Z0-9_]*)" % k)
        if k in slots:
            die(2, "--slot %s given twice" % k)
        slots[k] = v
    for k, v in slots.items():
        check_value(k, v)

    manifests = []
    for mid in a.module:
        m = load_manifest(mid, mdir)
        m["_id"] = mid
        manifests.append((os.path.join(mdir, mid), m))

    chosen = set(a.module)
    for _, m in manifests:
        for r in m.get("requires", []):
            if r not in chosen:
                die(1, "module %s requires module %s, which is not selected" % (m["_id"], r))
        for c in m.get("conflicts", []):
            if c in chosen:
                die(1, "module %s conflicts with module %s, which is also selected" % (m["_id"], c))

    declared = set()
    for _, m in manifests:
        declared.update(m.get("slots", {}))
        for k, rx in m["_pat"].items():
            if k in slots and rx.fullmatch(slots[k]) is None:
                die(2, "module %s: slot %s: value %r does not match its pattern %r"
                    % (m["_id"], k, slots[k], rx.pattern))
    for k in slots:
        if k not in declared:
            die(2, "unknown slot %r (declared: %s)" % (k, ", ".join(sorted(declared))))
    for k in sorted(declared):
        if k not in slots:
            die(2, "slot %r declared by a module but not given" % k)
    if a.layout == "monorepo" and "SERVICE" in slots:
        prefix = "services/" + slots["SERVICE"]
    else:
        prefix = ""

    dest = a.dest
    if os.path.islink(dest):
        die(1, "dest %s is a symlink; refusing to follow it" % dest)
    if os.path.lexists(dest) and (not os.path.isdir(dest) or os.listdir(dest)):
        die(1, "dest %s exists and is not an empty directory" % dest)

    umask = os.umask(0)
    os.umask(umask)

    plan = {}  # out path -> {"kind": link|file, "data", "mode", "mods": [ids], "merge": bool}
    bad_paths, bad_content, unplaced, bad_lit, bad_esc, bad_link = [], [], [], [], [], []
    for mod_path, m in manifests:
        mid = m["_id"]
        src = os.path.normpath(os.path.join(mod_path, m["source"]))
        real_src = os.path.realpath(src)
        pkg = os.path.realpath(os.path.dirname(os.path.abspath(mdir)))
        if not (real_src == pkg or real_src.startswith(pkg + os.sep)):
            die(2, "module %s: source %s resolves outside %s" % (mid, m["source"], pkg))
        if not os.path.isdir(src):
            die(2, "module %s: source %s is not a directory" % (mid, src))
        ph = {k: m["_ph"].get(k, "<%s>" % k) for k in slots}
        if len(set(ph.values())) != len(ph):
            die(2, "module %s: two slots share one placeholder" % mid)
        sub = Subst(ph, slots, set(m["_lit"]) & set(slots))
        rules = [(glob_re(g), t) for g, t in m["placement"].items()]
        excl = [glob_re(g) for g in m.get("exclude", [])]
        merge_rx = [glob_re(g) for g in m.get("root_merge", {})]
        allow = set(m.get("slot_allow", []))
        strict = m.get("strict_slots", False) is True
        self_dir = src == os.path.normpath(mod_path)
        if a.layout == "monorepo" and "SERVICE" not in m.get("slots", {}) \
                and any(t == "unit" for _, t in rules):
            die(2, "module %s places files as `unit` but does not declare the SERVICE slot "
                "(required by layout monorepo)" % mid)
        for rel in candidates(src, a.strict_tracked):
            if (self_dir and rel == "module.json") or any(rx.match(rel) for rx in excl):
                continue
            target = next((t for rx, t in rules if rx.match(rel)), None)
            if target is None:
                unplaced.append(rel)
                continue
            out = sub.s(rel)
            if target == "unit" and prefix:
                out = prefix + "/" + out
            if escapes("/assemble-root", out):
                bad_esc.append("%r (module %s)" % (out, mid))
                continue
            if re.search(r"<[^<>/]*>", out):
                bad_paths.append(out)
            full = os.path.join(src, rel)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                tgt = os.readlink(full)
                norm = os.path.normpath(os.path.join(os.path.dirname(rel), tgt))
                if os.path.isabs(tgt) or "\0" in tgt or norm == ".." or norm.startswith("../"):
                    bad_link.append("%s -> %s (module %s)" % (out, tgt, mid))
                    continue
                ent = {"kind": "link", "data": tgt, "mode": 0}
            elif stat.S_ISREG(st.st_mode):
                with open(full, "rb") as f:
                    data = sub.b(f.read())
                for k in slots:
                    if ("<%s>" % k).encode() in data:
                        bad_content.append(out)
                        break
                else:
                    if strict:
                        stray = sorted({t.decode() for t in TOKEN.findall(data)} - allow)
                        if stray:
                            bad_content.append("%s (<%s>)" % (out, ">, <".join(stray)))
                mode = (stat.S_IMODE(st.st_mode) & ~umask) | stat.S_IWUSR
                ent = {"kind": "file", "data": data, "mode": mode}
            else:
                bad_link.append("%s is not a regular file or link (module %s)" % (out, mid))
                continue
            ent["mods"] = [mid]
            ent["merge"] = any(rx.match(out) for rx in merge_rx)
            old = plan.get(out)
            if old is None:
                plan[out] = ent
            elif (old["kind"], old["data"], old["mode"]) == (ent["kind"], ent["data"], ent["mode"]):
                if mid not in old["mods"]:
                    old["mods"].append(mid)
            elif ent["kind"] == "file" and old["kind"] == "file" and old["merge"] and ent["merge"]:
                names = " + ".join(old["mods"]) + " and " + mid
                if old["mode"] != ent["mode"]:
                    die(1, "modules %s: root_merge of %s refused: different mode" % (names, out))
                try:
                    old["data"] = union_lines(old["data"], ent["data"])
                except ValueError as e:
                    die(1, "modules %s: root_merge union-lines of %s refused: %s" % (names, out, e))
                if mid not in old["mods"]:
                    old["mods"].append(mid)
            else:
                if old["kind"] != ent["kind"]:
                    why = "link vs file"
                elif old["kind"] == "link":
                    why = "different link target"
                elif old["data"] == ent["data"]:
                    why = "different mode"
                else:
                    why = "different content"
                if old["mods"] == [mid]:
                    die(1, "module %s places %s twice (%s)" % (mid, out, why))
                die(1, "modules %s and %s both place %s (%s); identical files are written once, "
                    "only root_merge union-lines merges text; for YAML/JSON a monorepo-root "
                    "module should own the file" % (" + ".join(old["mods"]), mid, out, why))
        for k in sorted(m["_lit"]):
            if k in slots and k not in sub.hits:
                bad_lit.append("module %s: literal %r of slot %s never occurs" % (mid, m["_lit"][k], k))

    if unplaced or bad_paths or bad_content or bad_lit or bad_esc or bad_link:
        for label, items in (("literal", bad_lit), ("unplaced", unplaced), ("path", bad_paths),
                             ("file", bad_content), ("escape", bad_esc), ("link", bad_link)):
            for p in items:
                sys.stderr.write("    %s: %s\n" % (label, p))
        die(1, "refused -- %d unplaced file(s), %d path(s), %d file(s) with a leftover slot, "
            "%d unused literal slot(s), %d path escape(s), %d bad link(s)"
            % (len(unplaced), len(bad_paths), len(bad_content), len(bad_lit), len(bad_esc), len(bad_link)))
    if not plan:
        die(1, "nothing to assemble")

    # a planned file or link may not also be a directory on the way to another entry
    for out in sorted(plan):
        parts = out.split("/")
        for i in range(1, len(parts)):
            pre = "/".join(parts[:i])
            if pre in plan:
                o, e = plan[pre], plan[out]
                die(1, "path conflict: module %s places %s as a %s, but module %s places %s beneath it; "
                    "nothing written" % (" + ".join(o["mods"]), pre, o["kind"], " + ".join(e["mods"]), out))

    # write into a fresh temp dir beside dest, then rename: dest is untouched on any failure
    dest_abs = os.path.abspath(dest)
    anc = os.path.dirname(dest_abs)
    while not os.path.lexists(anc):
        anc = os.path.dirname(anc)
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix=".assemble-", dir=anc)
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        for out in sorted(plan):
            if escapes(tmp, out):
                die(1, "refused: %r resolves outside dest" % out)
            p = os.path.join(tmp, out)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if escapes(tmp, out):
                die(1, "refused: %r resolves outside dest" % out)
            e = plan[out]
            if e["kind"] == "link":
                os.symlink(e["data"], p)
            else:
                fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(e["data"])
                    os.fchmod(f.fileno(), e["mode"])
        os.chmod(tmp, 0o777 & ~umask)
        os.makedirs(os.path.dirname(dest_abs), exist_ok=True)
        if os.path.islink(dest) or (os.path.lexists(dest) and (not os.path.isdir(dest) or os.listdir(dest))):
            die(1, "dest %s changed while assembling; nothing written" % dest)
        os.rename(tmp, dest_abs)
    finally:
        if tmp is not None and os.path.lexists(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
    print("assemble: ok -- %d file(s), layout %s, slots remaining: 0" % (len(plan), a.layout))


def main():
    try:
        run()
    except OSError as e:
        die(1, "I/O error, nothing written: %s" % e)
    except Exception as e:  # never a traceback for the user
        die(1, "internal error, nothing written: %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
