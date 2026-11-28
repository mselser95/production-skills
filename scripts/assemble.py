#!/usr/bin/env python3
"""assemble.py -- build a repo tree from prod-new modules.

Usage:
  python3 -I -B scripts/assemble.py --dest DIR --layout single|monorepo \
      [--module ID ...] [--unit MODULE:ID[,SLOT=VALUE...] ...] --slot NAME=VALUE [--slot ...] \
      [--modules-dir DIR] [--strict-tracked]

A module is prod-new/modules/<id>/module.json: `source` (relative to the module
dir), `slots`, and `placement` (ordered glob -> "root" | "unit", first match
wins). Every source file must match a glob (no catch-all, so a dropped glob is
an error, not a silent relocation). Layout `single`: root and unit are the repo
root. Layout `monorepo`: unit is services/<SERVICE>, and a module that places
anything as `unit` must declare (and be given) the SERVICE slot, else exit 2.

UNIT INSTANCES (--unit). `--module M` is ONE instance of M with the global --slot values (its
unit directory is services/<SERVICE>, exactly as before). `--unit M:ID[,K=V...]` (repeatable;
`,` separates, and no value can contain `,` or `:`, so it parses without ambiguity) is one
instance of M with its OWN slots: ID fills the module's unit slot (manifest key `unit_slot`,
default `SERVICE`), global --slot values apply unless the instance overrides them (overriding
the unit slot itself is exit 2, a K the module does not declare is exit 2). The same module may
appear in several --unit with different ids; --module and --unit may be mixed. Every instance is
built into the ONE temp tree and renamed once. Unit directory of an instance (layout monorepo):
by manifest `unit.kind` (default service): service services/<id>, app apps/<id>, package
packages/<id>, database db; layout single: the root. A unit instance is refused (exit 2, before
anything is written) when its id repeats another --unit id (compared NFC + case-folded, so ids
differing only by case are the same id) or its unit directory is equal to / nested in /
containing another instance's (the check needs one side to be a --unit: several plain --module
instances keep sharing one directory as before). Slot values, links, probes, `.git` rules apply
per instance; the id obeys the value grammar and the module's max_len/charset. A link of a
unit-placed file whose target resolves into ANOTHER instance's unit directory is refused (exit
1: it couples two units). ROOT files are contributed once per instance: identical bytes are
written once, root_merge (declared by every contributor) merges, anything else is exit 1 naming
the path and both contributors (`module[unit-id]`); for two instances of ONE module the message
says the module places a per-unit (slot-dependent) file at the root. Error messages name
`module[unit-id]`.

REPO INVENTORY. Layout monorepo, when a module contributes a root `repo.yaml`: the assembler
fills the units list WITHOUT reading YAML. The file (after slot substitution, what would be
written) is accepted only if EVERY line is one of these shapes, else exit 2 with the line number
and the reason: blank; a whole-line comment `^ *#.*$`; a top-level scalar `key: value` (key
[a-z][a-z0-9_]*; value a plain token [A-Za-z0-9][A-Za-z0-9._-]* or a one-line double-quoted string
without backslash or inner quote; no trailing comment); a mapping opener `key:` followed by one or
more children `  key: value` (two spaces, ONE nesting level); exactly ONE line `units: []`. And:
no top-level (or child) key twice, `units` included; no line starting with `---` or `...`; none of
`| > & * ! % @ { } [ ]`, a backtick or a backslash, outside the `units: []` line and comments; and THE ALPHABET: an
inventory file is ASCII -- every character is printable ASCII (0x20-0x7E) or a newline, in comments and
quoted values too (an allow-list: anything else, e.g. U+FFFE, an accented letter, NBSP, DEL, a tab, CR or
BOM, is exit 2 with the line number and the code point), and the bytes must decode as strict UTF-8
(else exit 2); the file ends with a newline. Anything that is not this flat shape
(a second document, a block or multi-line scalar, a flow mapping, an anchor) is a refusal, so the
one `units: []` line is always a real top-level key. That line becomes `units:` plus one flow-style
line per unit: `  - { id: "x", kind: "service", language: "go", path: "services/x" }`, every scalar
json.dumps() quoted (JSON strings are YAML strings), sorted by path. The assembler re-reads its OWN
output with the same line rules plus that entry shape before the final rename; a mismatch is an
internal error, exit 2, nothing written. Units: each instance that places unit files (kind and
language from the module's `unit`; none declared is exit 2) and each unit a module declares with
`units`. With an inventory every id must match ^[a-z][a-z0-9-]*$ (the schema of the generated
repository), else exit 2 naming the id. Two units at one path: exit 1. No repo.yaml, nothing is
generated; layout single never generates.

DECLARED UNITS (manifest key `units`, a module that ships SEVERAL fixed units, e.g. two workspace
packages placed as root files): a list of {id, kind, language, path}; mutually exclusive with
`unit`; `path` must equal the directory the kind rule gives for that id (packages/<id>, apps/<id>,
services/<id>, db); id and path hold no slot placeholder; at least one file the module places must
land inside that directory (else exit 2). Declared ids share the global id uniqueness (NFC +
casefold) and the directory clash rules of --unit instances. Such a module has no unit slot:
`--unit MODULE:ID` on it is exit 2, use --module. The module's OWN root files may land inside its
OWN declared directories; any other module's files there are refused.

ROOT FILES INSIDE A UNIT DIRECTORY (layout monorepo): a path placed as `root` that falls inside
the unit directory of ANY instance (or declared unit) is refused, exit 1, naming the path, the
contributing module and the unit (a module's own declared units excepted). LINKS of a unit-placed
file (layout monorepo) must resolve inside THEIR OWN unit directory: a link to another unit is
refused (couples), and so is a link to the repository root, an ancestor of the unit (`..`) or
anything else outside the unit (no real module places a link today). This holds for EVERY planned
link whose OUTPUT path lies inside any unit directory (an instance's or a declared one), however it
was placed and whichever module placed it: a declared-unit module places its files as `root`, so its
links inside its declared directories are checked the same way. A ROOT link (output outside every
unit directory) whose target lies inside a unit directory couples the root to a unit and is refused,
exit 1, naming link, target and unit; a root link to a root file is fine. Layout single is unchanged.
ASYMMETRY: a `--unit` instance may not place a ROOT file inside its own unit directory (it must use a
`unit` placement), while a declared-unit module's root files land in its declared directories by
definition, because declared units have no `unit` placement.
In layout `single` the equal/nested directory clash does not apply between an instance (whose unit
directory is the root) and a module's declared units, which are just directories of root-placed files
there; real file collisions are still exit 1 by the same-path rule, and two modules declaring the same
fixed directory still clash (exit 2) in both layouts.

SLOT VALUES. ONE grammar for every value, checked before anything else:
  1 to 64 characters (the length cap), each in [A-Za-z0-9._-], the first in
  [A-Za-z0-9] and the last not `.` (`x.` is an alias of `x` on Windows): no `/`
  `\\` `&` `<` whitespace NUL newline, no leading `-` or `.`, never empty, never
  `.` or `..`, ASCII only (a byte >= 0x80 is refused)
scripts/instantiate-template.sh is a thin wrapper over THIS tool (--layout single
--module service-go), so it has no grammar of its own (an EMPTY value is exit 2).
A slot may NARROW it with two FIXED options that cannot backtrack (there is no
regex option): `max_len` (integer 1..64) and `charset` (`lower` = [a-z]+;
`lower-digits-dash` = kebab-case [a-z0-9]+(-[a-z0-9]+)*; `identifier` =
[a-z_][a-z0-9_]*, a Python package name, whose leading `_` the grammar still
refuses). The grammar can never be widened. Because a value cannot contain `<`,
a substituted value is never a placeholder; and substitution is ONE pass over all
placeholders (longest first), so a value is never re-scanned and the result does
not depend on --slot order.

Slots are literal token replacement of <NAME> in contents (bytes) and in paths,
as the original shell tool did. A literal slot ({"literal": L}, L 3 to 64
chars, no `/`) replaces L itself, but only where L is not adjacent to [A-Za-z0-9_] on
the sides where L starts/ends with such a character: `@acme/pkg` and `acme/x`
hit, `acmes` and `xacme` do not (a `-` or `.` neighbour counts as a boundary).

SAFETY. Every final path is checked twice: the value grammar, and independently
`escapes()` (relative, no empty/`.`/`..` component, resolves under the real
dest). The whole tree is PLANNED first (no write until every check passed), then
written into a fresh temp dir created next to dest and renamed into place only
on full success; on any failure the temp dir is removed and dest is untouched.
Plan refusals: a file/link planned at a path that is also a proper prefix of
another entry (file vs dir, link redirect); two planned paths that are equal
after Unicode NFC normalisation and case folding (they are ONE file on a
case-insensitive filesystem; refused on every platform, so a tree assembled on
Linux is safe to check out on macOS), and the same fold for the prefix check; a
link whose target is absolute or, resolved from the link's OUTPUT location
(`dirname(out)/target`, target never substituted), leaves dest; a link target that
passes through, or ends at, another planned link (`d/L1 -> ..` then
`E -> d/L1/..` would leave dest through a link the lexical path cannot see: no
link-through-link); a source file with a setuid/setgid/sticky bit; an OUTPUT path
(after substitution and placement, however the candidate list was obtained) with
a component that is `.git` in any case or Unicode form (zero-width characters
ignored), ends in a dot or a space (`.git.` is `.git` on NTFS) or is `git~1`;
`.github`, `.gitignore`, `.gitattributes`, `.gitkeep`, `.gitmodules` stay allowed.
A module whose source tree, read by a filesystem walk, contains a `.git` entry
(a module directory that is itself a checkout) is refused, exit 1. A module
that yields no file is refused, exit 1. Symlinks inside a module are copied AS links
(like `cp -R`), never followed; writes use O_EXCL|O_NOFOLLOW. The template ships
no links today.

MODES (the same rule `cp -R` follows: the umask applies to the source mode on macOS
and GNU alike): a file gets (source & ~umask) | u+w; a
directory gets (source directory & 0777 & ~umask) | u+w, setuid/setgid/sticky
cleared; a directory that exists only because of the monorepo placement prefix
(`services/<SERVICE>`) gets 0755 & ~umask | u+w; the dest root gets
0777 & ~umask | u+w. When two modules share a directory the first module's source
directory mode wins. A directory exists only because a file or link lives in it:
an EMPTY source directory is dropped (the original shell tool removed it too).

INTERRUPTS. SIGINT, SIGTERM, SIGHUP and SIGQUIT remove the temp dir, print ONE
line (`assemble: interrupted -- nothing written`) and exit 130, 143, 129 and 131.
A signal after the final rename is ignored (the tree is complete, exit 0). The
cleanup itself cannot be interrupted and the exit code is that of the ORIGINAL
cause (a failure's code, or 128+N). Cleanup opens every directory of the temp
tree to the owner before removing it; a temp dir that still cannot be removed is
named on stderr. A closed stdout (BrokenPipe) after success is still exit 0.

DEST CONTRACT: dest must not exist, or be an empty directory (it is replaced by
the finished tree via rename; its own mode is not kept). A symlink dest is
refused. Missing parent dirs are created only after success.

Exit: 0 ok - 1 refused input (leftover slot, unplaced file, dest not empty or a
link, path escape, collision, conflict, requires/conflicts, unused literal,
special-mode file, reserved .git path, I/O failure while writing) - 128+N
interrupted by signal N - 2 usage or manifest error (bad --slot, bad value, bad
manifest) or an UNREADABLE SOURCE (a directory or file that cannot be read,
found at plan time so nothing is written).
Every refusal is ONE message on stderr (plus listed items); never a traceback.

MANIFEST KEYS (MANIFEST_KEYS below is the one list; unknown key -> exit 2):
  id            required; ^[a-z][a-z0-9-]*$ and equal to the directory name.
  source        required; relative path from the module dir. It must resolve to
                the module's own directory or a subdirectory of it, OR be exactly
                `../../template` resolving to <modules-dir>/../template (the
                legacy Go template). Nothing else.
  placement     required; {glob: "root"|"unit"}.
  requires      [module ids] each must also be selected, else exit 1.
  conflicts     [module ids] none may also be selected, else exit 1.
  unit_kind     optional string (informational).
  unit_slot     optional slot name (default SERVICE) that a --unit id fills; must be declared in
                `slots` when given.
  unit          optional {"kind": service|app|package|database, "language": str}: the inventory
                entry (repo.yaml) and, for kind, the unit directory. Both keys required when present.
  units         optional list of fixed units {id, kind, language, path} (see DECLARED UNITS).
  exclude       [globs] never placed, never reported unplaced; a glob containing
                `..` or starting with `/` is exit 2. When `source` is
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
                "max_len", "charset"}. A literal that never occurs is an error.
Duplicate JSON keys at any depth are exit 2 (nothing is "last wins").

CANDIDATE FILES. Inside a git work tree: `git ls-files --cached --others
--exclude-per-directory=.gitignore` restricted to the source dir, with user and
system git config neutralised (GIT_* stripped from the environment,
GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1, -c core.excludesFile=) and
.git/info/exclude not consulted. So these ship: every TRACKED file (working-tree
version; tracked-but-deleted is skipped) and every UNTRACKED file that no
.gitignore in the tree ignores. An untracked stray therefore ships; that breaks
byte parity with `cp -R`, so `--strict-tracked` refuses when any
untracked-not-ignored file exists in a source dir (and outside git, where
"tracked" is undefined). It is not the default because a module under
development is legitimately untracked; the parity selftest uses it. Outside git:
a filesystem walk. Two modules placing the same destination is allowed only when
kind, bytes and mode are identical after substitution, or root_merge applies.

SPECIAL ENTRIES AND UNREADABLE DIRECTORIES (one rule on both candidate paths; probe()).
ONE os.walk of the source tree, entries identified by lstat and never opened: a FIFO,
socket or device is exit 1 naming it; a directory that cannot be listed or traversed is
exit 2. Outside git the walk also gives the candidate list (and a `.git` is refused). In
git the candidate LIST still comes from git, so git-ignored build output is not shipped:
the walk visits every directory that holds a candidate or is an ancestor of one, plus
every other directory `.gitignore` does not ignore (an untracked unreadable directory is
an error). A special entry that git ignores (`git check-ignore`, which also reads
.git/info/exclude) is build junk and skipped; an untracked, not-ignored one is an error.

LINK TARGETS are walked component by component with the same reserved-name predicate as
output paths (.git in any case/Unicode form, trailing dot or space, git~1, any `:`): a
link into .git is a path to .git after `git init`. A STALE `.assemble-*` beside dest
(a killed run) is named on one stderr line and left alone. With stdout closed (`>&-`)
or unwritable the summary is dropped and the exit code is still 0 when the tree is done.
"""
import argparse
import json
import os
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata

VALUE_RX = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?")
SLOT_NAME_RX = re.compile(r"[A-Z][A-Z0-9_]*")
MODULE_ID_RX = re.compile(r"[a-z][a-z0-9-]*")
MANIFEST_KEYS = ("id", "source", "placement", "requires", "conflicts", "unit_kind",
                 "exclude", "root_merge", "strict_slots", "slot_allow", "slots", "unit_slot", "unit", "units")
SLOT_KEYS = ("description", "literal", "max_len", "charset")
CHARSETS = ("lower", "lower-digits-dash", "identifier")
MAX_VALUE = 64
LOWER = "abcdefghijklmnopqrstuvwxyz"
DIGITS = "0123456789"
SPECIAL = stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX
SIGNALS = tuple(getattr(signal, n) for n in ("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT") if hasattr(signal, n))
LAYOUTS = ("single", "monorepo")
UNIT_DIRS = {"service": "services", "app": "apps", "package": "packages", "database": None}
UNITS_LINE = "units: []"
INV_ID = re.compile(r"[a-z][a-z0-9-]*")
_SC = r'(?:[A-Za-z0-9][A-Za-z0-9._-]*|"[^"\\]*")'
_JS = r'"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-f]{4}))*"'
INV_TOP = re.compile(r"([a-z][a-z0-9_]*): " + _SC)
INV_OPEN = re.compile(r"([a-z][a-z0-9_]*):")
INV_CHILD = re.compile(r"  ([a-z][a-z0-9_]*): " + _SC)
INV_COMMENT = re.compile(r" *#.*")
INV_ENTRY = re.compile(r"  - \{ id: %s, kind: %s, language: %s, path: %s \}" % (_JS, _JS, _JS, _JS))
INV_FORBID = frozenset("|>&*!%@\\`{}[]")
STRATEGIES = ("union-lines",)
TOKEN = re.compile(rb"<([A-Z][A-Z0-9_]*)>")
WORD = re.compile(r"[A-Za-z0-9_]")


class Interrupted(BaseException):
    """A signal arrived; code is 128 + the signal number."""

    def __init__(self, code):
        BaseException.__init__(self, code)
        self.code = code


def ignore_signals():
    """Drop every handled signal: later ones are discarded, pending ones too."""
    for s in SIGNALS:
        signal.signal(s, signal.SIG_IGN)


def on_signal(signum, frame):
    ignore_signals()  # one interrupt is enough: the cleanup must not be interrupted again
    raise Interrupted(128 + signum)


TMP = [None]  # the temp dir that cleanup() still owes a removal


def cleanup():
    """Remove the temp dir. Not interruptible, idempotent (a second call is a no-op), and it
    makes every directory of the tree owner-accessible first (a 0500 source directory or a
    0777 umask leaves unreadable ones). A dir that cannot be removed is NAMED on stderr."""
    tmp, TMP[0] = TMP[0], None
    if tmp is None or not os.path.lexists(tmp):
        return
    ignore_signals()  # CLEANUP-MASK: a signal now must not abandon the removal half done
    try:
        os.chmod(tmp, 0o700)
        for dp, dns, _ in os.walk(tmp):  # top-down: a child is opened up before it is listed
            for d in dns:
                p = os.path.join(dp, d)
                if not os.path.islink(p):
                    os.chmod(p, 0o700)
        shutil.rmtree(tmp)
    except OSError as e:
        sys.stderr.write("assemble: could not remove temp dir %s: %s\n" % (tmp, e))


def unreadable(path, e):
    die(2, "unreadable source %s: %s" % (path, e.strerror or e))


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
    """The value grammar and length cap."""
    if len(v) > MAX_VALUE:
        die(2, "slot %s: value is %d characters; the cap is %d" % (name, len(v), MAX_VALUE))
    if not v.isascii() or VALUE_RX.fullmatch(v) is None:
        die(2, "slot %s: value %r is outside the value grammar "
            "[A-Za-z0-9][A-Za-z0-9._-]* (1 to %d characters, ASCII only)" % (name, v, MAX_VALUE))


def charset_ok(cs, v):
    """Fixed character-set tests, string methods only (nothing here can backtrack)."""
    if cs == "lower":
        return v != "" and all(c in LOWER for c in v)
    if cs == "lower-digits-dash":
        return v != "" and all(p != "" and all(c in LOWER + DIGITS for c in p) for p in v.split("-"))
    return v != "" and v[0] in LOWER + "_" and all(c in LOWER + DIGITS + "_" for c in v)


def fold(p):
    """The key two paths must NOT share: NFC, case-folded, NFC again."""
    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", p).casefold())


def dotgit(c):
    """True when a path component IS .git in any case / Unicode form (zero-width format
    characters are ignored, as git itself does on macOS)."""
    return fold("".join(ch for ch in c if unicodedata.category(ch) != "Cf")) == ".git"


def reserved(c):
    """A component no scaffold may ship: .git (any case), its NTFS aliases (a trailing dot or
    space is dropped by Windows: `.git.` IS `.git`; `git~1` is its short name), and ANY `:`
    (NTFS ends a name at the first `:`, so `.git:x` and `.git::$INDEX_ALLOCATION` are `.git`;
    a `:` is not valid in a Windows checkout either, so the stricter rule costs nothing)."""
    return (":" in c or dotgit(c) or (c not in (".", "..") and c.endswith((".", " ")))
            or fold(c) == "git~1")


def through_link(out, tgt, links):
    """The planned link a link target passes through, or None. `..` after a link would leave
    the link's own target, which the lexical path cannot see, so a link in the way is refused."""
    cur = out.split("/")[:-1]
    for c in tgt.split("/"):
        if c in ("", "."):
            continue
        if c == "..":
            if fold("/".join(cur)) in links:
                return "/".join(cur)
            if cur:
                cur.pop()
        else:
            cur.append(c)
            if fold("/".join(cur)) in links:
                return "/".join(cur)
    return None


def no_dups(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key %r" % k)
        d[k] = v
    return d


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


def git_ignored(src, env):
    """The paths git ignores under src, directories collapsed (`target/`); one process."""
    r = subprocess.run(["git", "-c", "core.excludesFile=", "-C", src, "ls-files", "-z", "--others",
                        "--ignored", "--directory", "--exclude-per-directory=.gitignore", "--", "."],
                       capture_output=True, env=env)
    if r.returncode != 0:
        die(1, "git ls-files --ignored failed in %s" % src)
    return {os.fsdecode(b) for b in r.stdout.split(b"\0") if b}


def git_check_ignore(src, env, rels):
    """The subset of rels git ignores (untracked ones only: a tracked path is never ignored)."""
    r = subprocess.run(["git", "-c", "core.excludesFile=", "-C", src, "check-ignore", "-z", "--stdin"],
                       input=b"\0".join(os.fsencode(x) for x in rels) + b"\0",
                       capture_output=True, env=env)
    if r.returncode not in (0, 1):
        die(1, "git check-ignore failed in %s" % src)
    return {os.fsdecode(b) for b in r.stdout.split(b"\0") if b}


def probe(src, mid, env=None, needed=None):
    """ONE os.walk of a module's source tree, nothing skipped silently, nothing opened (lstat only).
    Refuses (exit 1) an entry that is not a regular file, a directory or a symlink (FIFO, socket,
    device) and (exit 2) a directory it cannot list or traverse. Outside git (env None) the walk
    also gives the candidate list and refuses a `.git`. On the git path the candidate list comes
    from git (so ignored build output is not shipped); the walk visits every directory that holds
    a candidate or is an ancestor of one (`needed`) and every other directory git does not ignore
    (an untracked unreadable directory, or one holding only a FIFO, is an error); a special entry
    or an unreadable directory that git IGNORES is build junk and is skipped. Returns the files."""
    ignored = git_ignored(src, env) if env is not None else set()
    suspects, files = [], []

    def walk_error(e):
        unreadable(e.filename, e)

    for dp, dns, fns in os.walk(src, onerror=walk_error, followlinks=False):
        reld = os.path.relpath(dp, src)
        reld = "" if reld == "." else reld.replace(os.sep, "/")
        if not os.access(dp, os.R_OK | os.X_OK):
            unreadable(dp, PermissionError(13, "Permission denied"))
        dns.sort()
        descend = []
        for n in dns + sorted(fns):
            if dotgit(n):
                if env is None:  # SOURCE-GIT: a module directory that is a git checkout
                    die(1, "module %s: source tree %s contains %r: a module directory that is itself a "
                        "git checkout is a packaging mistake (a planted .git/hooks file would run on the "
                        "user's next git command); nothing written" % (mid, src, os.path.join(dp, n)))
                continue  # on the git path a .git is never listed, never entered
            full = os.path.join(dp, n)
            rel = (reld + "/" + n) if reld else n
            try:
                m = os.lstat(full).st_mode
            except OSError as e:
                unreadable(full, e)
            if stat.S_ISLNK(m):
                if env is None:
                    files.append(rel)
            elif stat.S_ISDIR(m):
                if env is None or rel in needed or (rel + "/") not in ignored:
                    descend.append(n)
            elif stat.S_ISREG(m):
                if env is None:
                    files.append(rel)
            elif env is None:  # SPECIAL-ENTRY (walk path)
                die(1, "module %s: %s is not a regular file, directory or link (FIFO, socket or device); "
                    "refused, never opened; nothing written" % (mid, full))
            else:
                suspects.append(rel)
        dns[:] = descend
    if suspects:  # SPECIAL-ENTRY (git path): only what git ignores is junk
        skip = git_check_ignore(src, env, suspects)
        loose = sorted(x for x in suspects if x not in skip)
        if loose:
            die(1, "module %s: %s is not a regular file, directory or link (FIFO, socket or device) and "
                "git does not ignore it; refused, never opened; nothing written"
                % (mid, os.path.join(src, loose[0])))
    return files


def candidates(src, strict, mid):
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
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                continue  # tracked but deleted
            except OSError as e:
                unreadable(full, e)  # NOT "deleted": an unreadable file is an error
            if stat.S_ISDIR(st.st_mode):
                continue  # a submodule
            out.add(rel)
        needed = {""}
        for rel in out:
            parts = rel.split("/")[:-1]
            needed.update("/".join(parts[:k + 1]) for k in range(len(parts)))
        probe(src, mid, env, needed)
        return sorted(out)
    return sorted(probe(src, mid))


def load_manifest(mid, mdir):
    mp = os.path.join(mdir, mid, "module.json")
    if not MODULE_ID_RX.fullmatch(mid) or not os.path.isfile(mp):
        die(2, "unknown module %r (no %s)" % (mid, mp))

    def bad(msg):
        die(2, "module %s: %s" % (mid, msg))

    try:
        with open(mp, encoding="utf-8") as f:
            m = json.load(f, object_pairs_hook=no_dups)
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
    for g in m.get("exclude", []):
        if ".." in g or g.startswith("/") or "\0" in g:
            bad("key 'exclude': glob %r must not contain `..`, start with `/` or hold NUL" % g)
    for key in ("requires", "conflicts"):
        for x in m.get(key, []):
            if not MODULE_ID_RX.fullmatch(x):
                bad("key %r: %r is not a module id" % (key, x))
    if "strict_slots" in m and not isinstance(m["strict_slots"], bool):
        bad("key 'strict_slots' must be true or false")
    if "unit_kind" in m and not isinstance(m["unit_kind"], str):
        bad("key 'unit_kind' must be a string")
    us = m.get("unit_slot", "SERVICE")
    if not isinstance(us, str) or not SLOT_NAME_RX.fullmatch(us):
        bad("key 'unit_slot' must be a slot name [A-Z][A-Z0-9_]*")
    if "unit_slot" in m and isinstance(m.get("slots", {}), dict) and us not in m.get("slots", {}):
        bad("key 'unit_slot' names slot %s, which the module does not declare" % us)
    if "unit" in m:
        u = m["unit"]
        if not isinstance(u, dict) or set(u) != {"kind", "language"} \
                or not all(isinstance(x, str) and x for x in u.values()):
            bad("key 'unit' must be {\"kind\": ..., \"language\": ...}, both non-empty strings")
        if u["kind"] not in UNIT_DIRS:
            bad("unit kind %r is not one of %s" % (u["kind"], ", ".join(sorted(UNIT_DIRS))))
        if not re.fullmatch(r"[a-z][a-z0-9]*", u["language"]):
            bad("unit language %r must match [a-z][a-z0-9]*" % u["language"])
    if "units" in m:
        if "unit" in m:
            bad("keys 'unit' and 'units' are mutually exclusive")
        us_ = m["units"]
        if not isinstance(us_, list) or not us_:
            bad("key 'units' must be a non-empty list of {id, kind, language, path}")
        for d in us_:
            if not isinstance(d, dict) or set(d) != {"id", "kind", "language", "path"} \
                    or not all(isinstance(x, str) and x for x in d.values()):
                bad("each entry of 'units' must be {\"id\", \"kind\", \"language\", \"path\"}, all non-empty strings")
            if "<" in d["id"] or "<" in d["path"]:
                bad("units entry %r: a slot placeholder is not allowed in a declared id or path "
                    "(declared units are fixed)" % d["id"])
            if not INV_ID.fullmatch(d["id"]):
                bad("units entry id %r must match ^[a-z][a-z0-9-]*$" % d["id"])
            if d["kind"] not in UNIT_DIRS:
                bad("units entry %r: kind %r is not one of %s" % (d["id"], d["kind"], ", ".join(sorted(UNIT_DIRS))))
            if not re.fullmatch(r"[a-z][a-z0-9]*", d["language"]):
                bad("units entry %r: language %r must match [a-z][a-z0-9]*" % (d["id"], d["language"]))
            base = UNIT_DIRS[d["kind"]]
            want = "db" if base is None else base + "/" + d["id"]
            if d["path"] != want:
                bad("units entry %r: path %r must be %r (the unit directory of kind %s)"
                    % (d["id"], d["path"], want, d["kind"]))
    rm = m.get("root_merge", {})
    if not isinstance(rm, dict):
        bad("key 'root_merge' must be an object")
    for g, strat in rm.items():
        if strat not in STRATEGIES:
            bad("root_merge %r -> %r (known: %s)" % (g, strat, ", ".join(STRATEGIES)))
    mslots = m.get("slots", {})
    if not isinstance(mslots, dict):
        bad("key 'slots' must be an object")
    m["_ph"], m["_lit"], m["_cs"], m["_ml"] = {}, {}, {}, {}
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
            if not isinstance(v["literal"], str) or not 3 <= len(v["literal"]) <= MAX_VALUE:
                bad("slot %s: literal must be a string of at least 3 and at most %d characters"
                    % (k, MAX_VALUE))
            if "/" in v["literal"] or "\0" in v["literal"]:
                bad("slot %s: literal must not contain `/` or NUL" % k)
            m["_ph"][k] = m["_lit"][k] = v["literal"]
        if "max_len" in v:
            if type(v["max_len"]) is not int or not 1 <= v["max_len"] <= MAX_VALUE:
                bad("slot %s: max_len must be an integer from 1 to %d" % (k, MAX_VALUE))
            m["_ml"][k] = v["max_len"]
        if "charset" in v:
            if v["charset"] not in CHARSETS:
                bad("slot %s: charset must be one of %s" % (k, ", ".join(CHARSETS)))
            m["_cs"][k] = v["charset"]
    return m


def block(on):
    if hasattr(signal, "pthread_sigmask"):
        signal.pthread_sigmask(signal.SIG_BLOCK if on else signal.SIG_UNBLOCK, SIGNALS)


def write_tree(plan, tmp, umask, dir_modes=None):
    """Write every planned entry under tmp (an existing, empty directory), then set directory
    modes. A path that would leave tmp, or that already exists, is refused (O_EXCL, no follow)."""
    dir_modes = dir_modes or {}
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    dirs = set()
    for out in sorted(plan):
        if escapes(tmp, out):
            die(1, "refused: %r resolves outside dest" % out)
        p = os.path.join(tmp, out)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        parts = out.split("/")[:-1]
        dirs.update("/".join(parts[:i + 1]) for i in range(len(parts)))
        e = plan[out]
        if e["kind"] == "link":
            os.symlink(e["data"], p)
        else:
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(e["data"])
                os.fchmod(f.fileno(), e["mode"])
    for d in sorted(dirs, key=lambda x: -x.count("/")):
        dp = os.path.join(tmp, d)
        if not os.path.islink(dp):
            os.chmod(dp, dir_modes.get(d, (0o777 & ~umask) | stat.S_IWUSR))
    os.chmod(tmp, (0o777 & ~umask) | stat.S_IWUSR)


def dirs_clash(a, b):
    """True when two unit directories (relative; "" is the repo root) are equal after NFC and case
    folding, or one contains the other: the two units would share files."""
    fa, fb = fold(a), fold(b)
    return fa == fb or fa == "" or fb == "" or fa.startswith(fb + "/") or fb.startswith(fa + "/")


def parse_unit(spec):
    """`MODULE:ID[,K=V...]` -> (module, id, {K: V}). Values cannot hold `,` or `:` (the grammar),
    so the split is unambiguous."""
    parts = spec.split(",")
    mid, sep, uid = parts[0].partition(":")
    if not sep or not mid or not uid:
        die(2, "bad --unit %r (want MODULE:ID[,SLOT=VALUE...])" % spec)
    if ":" in uid:  # redundant: the value grammar (check_value) refuses ':' in an id as well
        die(2, "bad --unit %r: a unit id may not contain ':'" % spec)
    over = {}
    for kv in parts[1:]:
        k, sep, v = kv.partition("=")
        if not sep or not SLOT_NAME_RX.fullmatch(k):
            die(2, "bad --unit %r: %r is not SLOT=VALUE with SLOT matching [A-Z][A-Z0-9_]*" % (spec, kv))
        if k in over:
            die(2, "bad --unit %r: slot %s given twice" % (spec, k))
        over[k] = v
    return mid, uid, over


def inventory_problem(data, generated=False):
    """The LINE ALLOW-LIST (see REPO INVENTORY in the header). `data` is bytes. Returns None when
    every line is allowed, else (line number, reason). generated=True also allows the entry lines
    this tool writes under `units:`, and wants exactly one units key (empty or filled)."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return 1, "not valid UTF-8"
    # THE ALPHABET (an allow-list, never a list of bad characters): printable ASCII and \n, nothing
    # else, in comments and quoted values too. A BOM, a tab, a CR, a control, a line separator, a
    # noncharacter (U+FFFE / U+FFFF) and every other non-ASCII character fall out of it by being
    # absent, so no code point can slip past by being missing from a deny-list.
    for n, ln in enumerate(text.split("\n"), 1):
        for ch in ln:
            if not 0x20 <= ord(ch) <= 0x7e:
                return n, "character U+%04X is not allowed (an inventory file is printable ASCII and newlines only)" % ord(ch)
    if not text.endswith("\n"):
        return text.count("\n") + 1, "the file must end with a newline"
    lines = text[:-1].split("\n")
    seen, units_empty, units_open = set(), 0, 0
    opener = None  # [key, line number, child count, child keys]

    def unclosed():
        return None if opener is None or opener[2] else (opener[1], "mapping `%s:` has no child line" % opener[0])
    for n, ln in enumerate(lines, 1):
        if ln.strip(" ") == "" or INV_COMMENT.fullmatch(ln):
            continue
        if ln.startswith("---") or ln.startswith("..."):  # also caught by the line-shape rules below
            return n, "a YAML document marker (`---` / `...`) is not allowed"
        if ln == UNITS_LINE:
            if unclosed():
                return unclosed()
            if "units" in seen:
                return n, "top-level key `units` appears twice"
            seen.add("units")
            units_empty += 1
            opener = None
            continue
        if ln.startswith(" ") and generated and opener is not None and opener[0] == "units" \
                and INV_ENTRY.fullmatch(ln):
            opener[2] += 1
            continue
        bad = next((c for c in ln if c in INV_FORBID), None)
        if bad is not None:
            return n, "forbidden character %r (only `units: []` and comments may hold it)" % bad
        if ln.startswith(" "):
            c = INV_CHILD.fullmatch(ln) if opener is not None else None
            if c is None:
                return n, "indented line is not a `  key: value` child of a `key:` line"
            if c.group(1) in opener[3]:
                return n, "child key `%s` appears twice" % c.group(1)
            opener[3].add(c.group(1))
            opener[2] += 1
            continue
        if unclosed():
            return unclosed()
        opener = None
        t, o = INV_TOP.fullmatch(ln), INV_OPEN.fullmatch(ln)
        if t is None and o is None:
            return n, "line is not one of the allowed shapes (blank, whole-line comment, `key: token`, " \
                      "`key: \"text\"`, `key:` with children, `units: []`)"
        key = (t or o).group(1)
        if key in seen:
            return n, "top-level key `%s` appears twice" % key
        seen.add(key)
        if o is not None:
            opener = [key, n, 0, set()]
            if generated and key == "units":
                units_open += 1
    if unclosed():
        return unclosed()
    if generated and opener is not None and opener[0] == "units" and not opener[2]:
        return opener[1], "units: has no entry"
    if units_empty + units_open != 1:
        return 0, "must hold exactly one line `units: []` (found %d)" % (units_empty + units_open)
    return None


def inv_rows(ents):
    """The generated entry lines, sorted by path. ents: (id, module, path, {kind, language})."""
    return ["  - { id: %s, kind: %s, language: %s, path: %s }" % (
        json.dumps(uid), json.dumps(u["kind"]), json.dumps(u["language"]), json.dumps(path))
        for uid, _, path, u in sorted(ents, key=lambda t: (t[2], t[0]))]


def fill_inventory(plan, insts):
    """Fill the `units: []` line of a contributed root repo.yaml with one entry per unit. Returns
    nothing; exits 2/1 on a contract violation."""
    e = plan.get("repo.yaml")
    if e is None or e["kind"] != "file":
        return
    who = " + ".join(e["mods"])
    prob = inventory_problem(e["data"])
    if prob is not None:
        die(2, "repo.yaml (module %s)%s: %s; the assembler fills the `units: []` line and accepts only a "
            "flat file (see REPO INVENTORY in its header)"
            % (who, " line %d" % prob[0] if prob[0] else "", prob[1]))
    ents = {}

    def add(uid, mid, path, u):
        if not INV_ID.fullmatch(uid):
            die(2, "unit id %r (module %s) does not match ^[a-z][a-z0-9-]*$, which the generated repo.yaml "
                "requires" % (uid, mid))
        if fold(path) in ents:
            die(1, "units %s and %s (modules %s and %s) share the path %s: repo.yaml lists one unit per path"
                % (ents[fold(path)][0], uid, ents[fold(path)][1], mid, path))
        ents[fold(path)] = (uid, mid, path, u)
    for i in insts:
        for d in i["decl"]:
            add(d["id"], i["mid"], d["path"], d)
        if not i["nunit"]:
            continue
        u = i["m"].get("unit")
        if u is None:
            die(2, "module %s places unit files but declares no `unit` {kind, language}; "
                "repo.yaml needs both" % i["label"])
        uid = i["uid"] if i["uid"] is not None else i["slots"].get(i["m"].get("unit_slot", "SERVICE"))
        if uid is None:
            die(2, "module %s places unit files but has no unit id for repo.yaml: give it with --unit"
                % i["mid"])
        path = i["dir"]
        if not path or escapes("/assemble-root", path) or any(reserved(c) for c in path.split("/")):
            die(1, "unit %s (module %s): unit path %r is not a safe relative path" % (uid, i["mid"], path))
        add(uid, i["mid"], path, u)
    rows = inv_rows(ents.values())
    if rows:
        lines = e["data"].decode().split("\n")
        at = lines.index(UNITS_LINE)
        lines[at:at + 1] = ["units:"] + rows
        data = "\n".join(lines).encode()
        prob = inventory_problem(data, generated=True)
        if prob is not None:
            die(2, "internal error: the generated repo.yaml fails its own line check (line %d: %s); "
                "nothing written" % prob)
        e["data"] = data


def run():
    ap = argparse.ArgumentParser(
        add_help=True, allow_abbrev=False, formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Build a repo tree from prod-new modules (see the header of this file).",
        epilog="Slot values: 1 to %d characters, ASCII, [A-Za-z0-9] first, then [A-Za-z0-9._-]; "
               "never empty, `.` or `..`. A module may narrow a slot with max_len and charset "
               "(lower, lower-digits-dash, identifier)." % MAX_VALUE)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--module", action="append", default=[],
                    help="one instance of MODULE with the global --slot values (repeatable)")
    ap.add_argument("--unit", action="append", default=[], metavar="MODULE:ID[,SLOT=VALUE...]",
                    help="one instance of MODULE whose unit id is ID (it fills the module's unit slot, "
                         "default SERVICE) and whose own slots are the K=V after the commas; global "
                         "--slot values apply unless overridden (repeatable, mixes with --module)")
    ap.add_argument("--slot", action="append", default=[])
    ap.add_argument("--modules-dir", default=None)
    ap.add_argument("--strict-tracked", action="store_true")
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(2 if e.code else 0)

    if a.layout not in LAYOUTS:
        die(2, "unknown layout %r (known: %s)" % (a.layout, ", ".join(LAYOUTS)))
    if not a.module and not a.unit:
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

    insts = []
    for mid in a.module:
        insts.append({"mid": mid, "uid": None, "over": {}, "explicit": False})
    for spec in a.unit:
        mid, uid, over = parse_unit(spec)
        check_value("unit id of module " + mid, uid)
        for k, v in over.items():
            check_value(k, v)
        insts.append({"mid": mid, "uid": uid, "over": over, "explicit": True})

    mans = {}
    for i in insts:
        if i["mid"] not in mans:
            mans[i["mid"]] = load_manifest(i["mid"], mdir)
            mans[i["mid"]]["_id"] = i["mid"]
        m = i["m"] = mans[i["mid"]]
        us = m.get("unit_slot", "SERVICE")
        i["decl"] = m.get("units", [])
        if i["explicit"] and i["decl"]:
            die(2, "module %s declares fixed `units` and has no unit slot: --unit %s:%s cannot be used, "
                "use --module %s" % (i["mid"], i["mid"], i["uid"], i["mid"]))
        i["label"] = "%s[%s]" % (i["mid"], i["uid"]) if i["explicit"] else i["mid"]
        i["slots"] = dict(slots)
        i["nunit"] = 0
        if i["explicit"]:
            for k in i["over"]:
                if k == us:
                    die(2, "unit %s: slot %s is the unit slot, the unit id fills it" % (i["label"], k))
                if k not in m.get("slots", {}):
                    die(2, "unit %s: module %s does not declare slot %s" % (i["label"], i["mid"], k))
            if us in m.get("slots", {}):
                i["slots"][us] = i["uid"]
            i["slots"].update(i["over"])

    chosen = set(mans)
    for m in mans.values():
        for r in m.get("requires", []):
            if r not in chosen:
                die(1, "module %s requires module %s, which is not selected" % (m["_id"], r))
        for c in m.get("conflicts", []):
            if c in chosen:
                die(1, "module %s conflicts with module %s, which is also selected" % (m["_id"], c))

    declared = set()
    for i in insts:
        m, sl = i["m"], i["slots"]
        declared.update(m.get("slots", {}))
        for k, n in m["_ml"].items():
            if k in sl and len(sl[k]) > n:
                die(2, "module %s: slot %s: value %r is longer than its max_len %d"
                    % (i["label"], k, sl[k], n))
        for k, cs in m["_cs"].items():
            if k in sl and not charset_ok(cs, sl[k]):
                die(2, "module %s: slot %s: value %r is outside its charset %s"
                    % (i["label"], k, sl[k], cs))
    for k in slots:
        if k not in declared:
            die(2, "unknown slot %r (declared: %s)" % (k, ", ".join(sorted(declared))))
    for i in insts:
        for k in sorted(i["m"].get("slots", {})):
            if k not in i["slots"]:
                if i["explicit"]:
                    die(2, "unit %s: slot %r is declared by module %s but not given (global --slot or "
                        "K=V after the id)" % (i["label"], k, i["mid"]))
                die(2, "slot %r declared by a module but not given" % k)

    # unit directories (None: the instance places nothing as `unit`)
    for i in insts:
        m = i["m"]
        us = m.get("unit_slot", "SERVICE")
        i["dir"], i["dir_err"] = None, None
        if not any(t == "unit" for t in m["placement"].values()):
            continue
        if a.layout == "single":
            i["dir"] = ""
            continue
        base = UNIT_DIRS[m.get("unit", {}).get("kind", "service")]
        if base is None:
            i["dir"] = "db"
        elif us not in m.get("slots", {}):
            i["dir_err"] = ("module %s places files as `unit` but does not declare the %s slot "
                            "(required by layout monorepo)" % (i["mid"], us))
        else:
            i["dir"] = base + "/" + i["slots"][us]
    # every unit with a directory: instances that place unit files, and declared units
    uall = []
    for i in insts:
        if i["dir"] is not None:
            uall.append({"label": i["label"], "dir": i["dir"], "id": i["uid"], "mid": i["mid"],
                         "explicit": i["explicit"], "inst": i, "decl": False})
        for d in i["decl"]:
            uall.append({"label": "%s[%s]" % (i["mid"], d["id"]), "dir": d["path"], "id": d["id"],
                         "mid": i["mid"], "explicit": True, "inst": i, "decl": True})
    seen = {}
    for x in (x for x in uall if x["explicit"]):
        k = fold(x["id"])
        if k in seen:
            die(2, "unit id %r (module %s) and unit id %r (module %s) are the same id (ids are compared "
                "NFC-normalised and case-insensitively); nothing written"
                % (seen[k]["id"], seen[k]["mid"], x["id"], x["mid"]))
        seen[k] = x
    for n, x in enumerate(uall):
        for y in uall[n + 1:]:
            if a.layout == "single" and x["decl"] != y["decl"]:
                continue  # single: an instance's unit directory is the root; declared dirs sit inside it
            if (x["explicit"] or y["explicit"]) and dirs_clash(x["dir"], y["dir"]):
                die(2, "unit %s and unit %s would share the unit directory %r (equal or nested); "
                    "nothing written" % (x["label"], y["label"], x["dir"] or ".") +
                    ("" if x["dir"] == y["dir"] else " vs %r" % (y["dir"] or ".")))

    dest = a.dest
    if os.path.islink(dest):
        die(1, "dest %s is a symlink; refusing to follow it" % dest)
    if os.path.lexists(dest) and (not os.path.isdir(dest) or os.listdir(dest)):
        die(1, "dest %s exists and is not an empty directory" % dest)

    umask = os.umask(0)
    os.umask(umask)

    plan = {}  # out path -> {"kind": link|file, "data", "mode", "mods": [ids], "merge": bool}
    dir_modes = {}  # out dir -> mode (first contributor wins)
    dstat = {}
    bad_paths, bad_content, unplaced, bad_lit, bad_esc, bad_link = [], [], [], [], [], []
    cand_cache = {}
    root_placed = []  # (out path, instance) of every file or link placed as `root`
    for i in insts:
        m, mid, islots = i["m"], i["label"], i["slots"]
        mod_path = os.path.join(mdir, i["mid"])
        prefix = i["dir"] or ""
        src = os.path.normpath(os.path.join(mod_path, m["source"]))
        real_src = os.path.realpath(src)
        real_mod = os.path.realpath(mod_path)
        legacy = os.path.realpath(os.path.join(mdir, "..", "template"))
        if not (real_src == real_mod or real_src.startswith(real_mod + os.sep)
                or (m["source"] == "../../template" and real_src == legacy)):
            die(2, "module %s: source %s resolves outside the module directory %s "
                "(only its own subtree, or exactly ../../template, is allowed)"
                % (mid, m["source"], real_mod))
        if not os.path.isdir(src):
            die(2, "module %s: source %s is not a directory" % (mid, src))
        ph = {k: m["_ph"].get(k, "<%s>" % k) for k in islots}
        if len(set(ph.values())) != len(ph):
            die(2, "module %s: two slots share one placeholder" % mid)
        sub = Subst(ph, islots, set(m["_lit"]) & set(islots))
        rules = [(glob_re(g), t) for g, t in m["placement"].items()]
        excl = [glob_re(g) for g in m.get("exclude", [])]
        merge_rx = [glob_re(g) for g in m.get("root_merge", {})]
        allow = set(m.get("slot_allow", []))
        strict = m.get("strict_slots", False) is True
        self_dir = src == os.path.normpath(mod_path)
        if i["dir_err"]:
            die(2, i["dir_err"])
        if src not in cand_cache:
            cand_cache[src] = candidates(src, a.strict_tracked, mid)
        cands = cand_cache[src]
        if not [r for r in cands if not (self_dir and r == "module.json")]:
            die(1, "module %s: source %s yields no files (an empty or unlistable source is an "
                "error, never \"nothing to copy\")" % (mid, src))
        for rel in cands:
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
            rc_ = next((c for c in out.split("/") if reserved(c)), None)
            if rc_ is not None:  # OUTPUT-GIT: whatever way the candidate list was obtained
                bad_esc.append("%r (module %s): path component %r is reserved (.git in any case, "
                               "a trailing dot or space, git~1)" % (out, mid, rc_))
                continue
            if re.search(r"<[^<>/]*>", out):
                bad_paths.append(out)
            full = os.path.join(src, rel)
            try:
                st = os.lstat(full)
                tgt = os.readlink(full) if stat.S_ISLNK(st.st_mode) else None
            except OSError as e:
                unreadable(full, e)
            if tgt is not None:
                norm = posixpath.normpath(posixpath.join(posixpath.dirname(out), tgt))
                if os.path.isabs(tgt) or "\0" in tgt or norm == ".." or norm.startswith("../"):
                    bad_link.append("%s -> %s (module %s)" % (out, tgt, mid))
                    continue
                rt = next((c for c in tgt.split("/") if reserved(c)), None)
                if rt is not None:  # TARGET-GIT: a link INTO .git is a path to .git after `git init`
                    bad_link.append("%s -> %s (module %s): target component %r is reserved (.git in "
                                    "any case, a trailing dot or space, git~1, a colon)"
                                    % (out, tgt, mid, rt))
                    continue
                ent = {"kind": "link", "data": tgt, "mode": 0, "norm": norm,
                       "udir": i["dir"] if target == "unit" else None}
            elif stat.S_ISREG(st.st_mode):
                if st.st_mode & SPECIAL:
                    bad_link.append("%s has a setuid/setgid/sticky bit (%o) (module %s)"
                                    % (rel, stat.S_IMODE(st.st_mode), mid))
                    continue
                try:
                    with open(full, "rb") as f:
                        data = sub.b(f.read())
                except OSError as e:
                    unreadable(full, e)  # at PLAN time: nothing has been written yet
                for k in islots:
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
            rparts, oparts = rel.split("/")[:-1], out.split("/")[:-1]
            plen = len(oparts) - len(rparts)
            for n in range(len(oparts)):
                od = "/".join(oparts[:n + 1])
                if od in dir_modes:
                    continue
                if n < plen:
                    dir_modes[od] = (0o755 & ~umask) | stat.S_IWUSR
                    continue
                sd = os.path.join(src, *rparts[:n - plen + 1])
                if sd not in dstat:
                    try:
                        dstat[sd] = stat.S_IMODE(os.lstat(sd).st_mode) & 0o777
                    except OSError:
                        dstat[sd] = 0o777
                dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR
            ent["mods"] = [mid]
            ent["by"] = [i["mid"]]
            if target == "root":
                root_placed.append((out, i))
            if target == "unit":
                i["nunit"] += 1
            ent["merge"] = any(rx.match(out) for rx in merge_rx)
            old = plan.get(out)
            if old is None:
                plan[out] = ent
            elif (old["kind"], old["data"], old["mode"]) == (ent["kind"], ent["data"], ent["mode"]):
                if mid not in old["mods"]:
                    old["mods"].append(mid)
                    old["by"].append(i["mid"])
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
                    old["by"].append(i["mid"])
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
                if i["mid"] in old["by"]:
                    die(1, "module %s places a per-unit file at the root: %s differs between %s and %s "
                        "(%s); a root file must not depend on the unit's slots, so the module must place "
                        "it per unit or the root must be owned by one module"
                        % (i["mid"], out, " + ".join(old["mods"]), mid, why))
                die(1, "modules %s and %s both place %s (%s); identical files are written once, "
                    "only root_merge union-lines merges text; for YAML/JSON a monorepo-root "
                    "module should own the file" % (" + ".join(old["mods"]), mid, out, why))
        for k in sorted(m["_lit"]):
            if k in islots and k not in sub.hits:
                bad_lit.append("module %s: literal %r of slot %s never occurs" % (mid, m["_lit"][k], k))

    links = {fold(o) for o, e in plan.items() if e["kind"] == "link"}
    for out in sorted(plan):
        e = plan[out]
        via = through_link(out, e["data"], links) if e["kind"] == "link" else None
        if via is not None:
            bad_link.append("%s -> %s (module %s): the target passes through planned link %s"
                            % (out, e["data"], " + ".join(e["mods"]), via))

    for out in sorted(plan):
        e = plan[out]
        if e["kind"] != "link" or a.layout != "monorepo":
            continue
        ok_, nk = fold(out), fold(e["norm"])
        # A link whose OUTPUT path lies inside ANY unit directory (an instance's or a declared one)
        # belongs to that unit, however it was placed (a declared-unit module places it as root).
        own = next((y["dir"] for y in uall if y["dir"] and ok_.startswith(fold(y["dir"]) + "/")), None)
        if own is None:
            # A root link: the root must not couple itself to a unit.
            for y in uall:
                d = fold(y["dir"])
                if d and (nk == d or nk.startswith(d + "/")):
                    bad_link.append("%s -> %s (module %s): a root link whose target %s lies inside the "
                                    "unit directory %s of unit %s; a link from the root couples it to a unit"
                                    % (out, e["data"], " + ".join(e["mods"]), e["norm"], y["dir"], y["label"]))
                    break
            continue
        uk = fold(own)
        for y in uall:
            d = y["dir"]
            if d and fold(d) != uk and (nk == fold(d) or nk.startswith(fold(d) + "/")):
                bad_link.append("%s -> %s (module %s): the target reaches the unit directory %s of "
                                "unit %s; a link between units couples them"
                                % (out, e["data"], " + ".join(e["mods"]), d, y["label"]))
                break
        else:
            if not (nk == uk or nk.startswith(uk + "/")):
                bad_link.append("%s -> %s (module %s): the target %s is outside the unit directory %s; a "
                                "link of a unit must stay inside its own unit"
                                % (out, e["data"], " + ".join(e["mods"]), e["norm"], own))

    if a.layout == "monorepo":
        for out, r in root_placed:
            ok_ = fold(out)
            for y in uall:
                d = fold(y["dir"])
                if d and (ok_ == d or ok_.startswith(d + "/")) and not (y["decl"] and y["inst"] is r):
                    bad_esc.append("%r (module %s): a root file inside the unit directory %s of unit %s"
                                   % (out, r["label"], y["dir"], y["label"]))
                    break
    for i in insts:
        for d in i["decl"]:
            pre = fold(d["path"]) + "/"
            if not any(i["label"] in e["mods"] and fold(o).startswith(pre) for o, e in plan.items()):
                die(2, "module %s declares unit %s at %s, but places no file inside that directory"
                    % (i["mid"], d["id"], d["path"]))

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
    if a.layout == "monorepo":
        fill_inventory(plan, insts)

    # two paths one file on a case-insensitive / normalising filesystem, and a planned file or
    # link may not also be a directory on the way to another entry (both on the folded path)
    kmap = {}
    for out in sorted(plan):
        k = fold(out)
        if k in kmap:
            die(1, "path collision: %r (module %s) and %r (module %s) differ only by case or "
                "Unicode normalisation; they are one file on a case-insensitive filesystem; "
                "nothing written" % (kmap[k], " + ".join(plan[kmap[k]]["mods"]), out,
                                     " + ".join(plan[out]["mods"])))
        kmap[k] = out
    for out in sorted(plan):
        parts = fold(out).split("/")
        for i in range(1, len(parts)):
            pre = kmap.get("/".join(parts[:i]))
            if pre is not None:
                o, e = plan[pre], plan[out]
                die(1, "path conflict: module %s places %s as a %s, but module %s places %s beneath it; "
                    "nothing written" % (" + ".join(o["mods"]), pre, o["kind"], " + ".join(e["mods"]), out))

    # write into a fresh temp dir beside dest, then rename: dest is untouched on any failure
    dest_abs = os.path.abspath(dest)
    anc = os.path.dirname(dest_abs)
    while not os.path.lexists(anc):
        anc = os.path.dirname(anc)
    stale = sorted(n for n in os.listdir(anc) if n.startswith(".assemble-")) if os.path.isdir(anc) else []
    if stale:  # STALE-TMP: a killed run's leftover; named, never deleted
        sys.stderr.write("assemble: stale temp dir(s) from an earlier killed run beside dest, left alone: %s\n"
                         % ", ".join(os.path.join(anc, n) for n in stale[:5]))
    try:
        block(True)  # no signal between mkdtemp and the assignment that lets cleanup() remove it
        try:
            tmp = tempfile.mkdtemp(prefix=".assemble-", dir=anc)
            TMP[0] = tmp
        finally:
            block(False)
        os.chmod(tmp, 0o700)  # MKDTEMP-CHMOD: under umask 0777 mkdtemp yields a mode-000 directory
        write_tree(plan, tmp, umask, dir_modes)
        block(True)  # the commit: a signal now waits, and is dropped once the rename happened
        try:
            os.makedirs(os.path.dirname(dest_abs), exist_ok=True)
            if os.path.islink(dest) or (os.path.lexists(dest) and (not os.path.isdir(dest) or os.listdir(dest))):
                die(1, "dest %s changed while assembling; nothing written" % dest)
            os.rename(tmp, dest_abs)
            TMP[0] = None
            ignore_signals()  # COMMIT-IGNORE: the tree is complete; a late signal is dropped
        except BaseException:
            ignore_signals()  # CAUSE-WINS: a pending signal must not replace the real failure
            raise
        finally:
            block(False)
    finally:
        cleanup()
    if sys.stdout is not None:  # STDOUT-NONE: `>&-` leaves no sys.stdout; the tree is complete either way
        try:
            print("assemble: ok -- %d file(s), layout %s, slots remaining: 0" % (len(plan), a.layout))
            sys.stdout.flush()
        except (OSError, ValueError):
            # a closed pipe, a full disk (/dev/full): the summary is lost, the tree is complete, so
            # this is success; point fd 1 at /dev/null so the flush at exit cannot fail again
            try:
                os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            except (OSError, ValueError):
                pass


def main():
    for sg in SIGNALS:
        signal.signal(sg, on_signal)
    try:
        run()
    except (Interrupted, KeyboardInterrupt) as e:
        sys.stderr.write("assemble: interrupted -- nothing written\n")
        sys.exit(e.code if isinstance(e, Interrupted) else 130)
    except OSError as e:
        die(1, "I/O error, nothing written: %s" % e)
    except Exception as e:  # never a traceback for the user
        die(1, "internal error, nothing written: %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
