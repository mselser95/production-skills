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
                 "exclude", "root_merge", "strict_slots", "slot_allow", "slots")
SLOT_KEYS = ("description", "literal", "max_len", "charset")
CHARSETS = ("lower", "lower-digits-dash", "identifier")
MAX_VALUE = 64
LOWER = "abcdefghijklmnopqrstuvwxyz"
DIGITS = "0123456789"
SPECIAL = stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX
SIGNALS = tuple(getattr(signal, n) for n in ("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT") if hasattr(signal, n))
LAYOUTS = ("single", "monorepo")
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


def run():
    ap = argparse.ArgumentParser(
        add_help=True, allow_abbrev=False, formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Build a repo tree from prod-new modules (see the header of this file).",
        epilog="Slot values: 1 to %d characters, ASCII, [A-Za-z0-9] first, then [A-Za-z0-9._-]; "
               "never empty, `.` or `..`. A module may narrow a slot with max_len and charset "
               "(lower, lower-digits-dash, identifier)." % MAX_VALUE)
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
        for k, n in m["_ml"].items():
            if k in slots and len(slots[k]) > n:
                die(2, "module %s: slot %s: value %r is longer than its max_len %d"
                    % (m["_id"], k, slots[k], n))
        for k, cs in m["_cs"].items():
            if k in slots and not charset_ok(cs, slots[k]):
                die(2, "module %s: slot %s: value %r is outside its charset %s"
                    % (m["_id"], k, slots[k], cs))
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
    dir_modes = {}  # out dir -> mode (first contributor wins)
    dstat = {}
    bad_paths, bad_content, unplaced, bad_lit, bad_esc, bad_link = [], [], [], [], [], []
    for mod_path, m in manifests:
        mid = m["_id"]
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
        cands = candidates(src, a.strict_tracked, mid)
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
                ent = {"kind": "link", "data": tgt, "mode": 0}
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
            rparts, oparts = rel.split("/")[:-1], out.split("/")[:-1]
            plen = len(oparts) - len(rparts)
            for i in range(len(oparts)):
                od = "/".join(oparts[:i + 1])
                if od in dir_modes:
                    continue
                if i < plen:
                    dir_modes[od] = (0o755 & ~umask) | stat.S_IWUSR
                    continue
                sd = os.path.join(src, *rparts[:i - plen + 1])
                if sd not in dstat:
                    try:
                        dstat[sd] = stat.S_IMODE(os.lstat(sd).st_mode) & 0o777
                    except OSError:
                        dstat[sd] = 0o777
                dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR
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

    links = {fold(o) for o, e in plan.items() if e["kind"] == "link"}
    for out in sorted(plan):
        e = plan[out]
        via = through_link(out, e["data"], links) if e["kind"] == "link" else None
        if via is not None:
            bad_link.append("%s -> %s (module %s): the target passes through planned link %s"
                            % (out, e["data"], " + ".join(e["mods"]), via))

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
