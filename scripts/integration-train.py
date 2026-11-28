#!/usr/bin/env python3
"""integration-train: verify a batch of reviewed changes ONCE on the joined tree.

Run it as:  python3 -I -B scripts/integration-train.py --base REF --verify CMD CAND...
Python 3 standard library only. It NEVER pushes, merges or touches a remote.
"""
import argparse
import atexit
import json
import math
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata

EPILOG = """\
What this tool does to your repository:
 It READS objects (through a git alternates file) and, when --keep is given and a
 batch landed, WRITES ONE branch at the end: the landed commits' objects (index-pack)
 and the new ref (update-ref, create-only). Nothing else, ever: no worktree, ref,
 config, index or lock in your repository, and without --keep nothing at all. It runs
 none of your hooks, filters, merge drivers, diff drivers, textconv, signature
 programs, fsmonitor, editors, pagers, credential helpers or aliases, because git never
 runs under your configuration: every join happens in a PRIVATE bare repository the
 tool creates under TMPDIR (itrain-*/repo.git) whose config the tool writes itself.
 Filters are NOT applied (an LFS-style repo's pointer files are plain files: a verify
 command that needs smudged content sees pointers). The VERIFY command is yours: it
 runs with your environment minus every repo-pointing variable, in a fresh directory
 (itrain-*/w<k>/tree) used by that one run only, with a fresh TMPDIR (itrain-*/w<k>/tmp)
 and stdin on /dev/null; HOME stays yours, so a verify must not keep state under HOME
 or in absolute paths (one that climbs two levels up reaches the shared private root).
 A verify child that calls setsid survives a timeout (the tool cannot see it). SIGKILL
 of the tool leaves exactly one itrain-* directory under TMPDIR and nothing in your
 repository; a later start prints a one-line notice for such directories older than a
 day (it never deletes them). A caller that is a partial clone or a shallow clone is
 refused (exit 2): a missing object must be an error, never a fetch.

Algorithm (one batch per invocation):
 1. Admission, in the given order, joining into one admission worktree: one whose
    changed paths overlap an admitted member is 'deferred: overlaps <other> on
    <path>'; beyond the window it is deferred 'batch full'; one that does not
    apply (cherry-pick / squash conflict) is 'ejected: conflict' (it does not apply
    cleanly on the joined tree, no cause guessed); one with NO net change (an empty
    commit, a branch whose commits cancel out, a change the base already has) is
    'ejected: empty'; one with no common ancestor with the base is 'ejected:
    unrelated'; on a filesystem that folds case or Unicode form, one adding a path that
    collides with a path of the joined tree is 'ejected:
    unrepresentable-on-this-filesystem' (a base that collides itself is exit 2);
    none of them runs verify. The window is --max-batch, or 'next' from --state. The
    changed-path set of a candidate is the union of (a) `git diff --name-status -z
    --no-renames BASE...TIP` and (b) `git log -z --format= --name-only --no-renames -m
    TIP ^BASE`: NUL delimited, merge commits included, a rename contributes both names
    (over-approximating only defers).
 2. Join: inside TEMPORARY worktrees of the private repository only, one commit per
    candidate in the given order: a single-commit candidate is `git cherry-pick`ed; a
    multi-commit branch (or a merge commit) is `git merge --squash`ed and committed as
    ONE commit whose subject is the candidate name, whose body lists its original
    subjects and whose AUTHOR is the candidate's last author. The committer is always
    'integration-train <train@localhost>'. A conflict is detected by exit status and
    undone. Needs git >= 2.31 (checked at start, exit 2 otherwise). Prefix commits are
    cached; every new object lives in the private object store.
 3. EVERY verify run (first run, flaky rerun, each bisection step, the final
    re-join, each recovery) executes in a BRAND-NEW worktree checked out at the exact
    commit under test, in its own parent directory; before verify starts the tool
    asserts HEAD is that commit and `git status --porcelain --ignored` is empty (else
    exit 2). No artefact is ever reused between runs.
 4. Verify the whole batch once. Green: landed.
 5. Red: bisect by halving. Verify the first half; green means the second half is
    known to hold the failure, so its OWN whole run is skipped and it is split
    directly (a singleton is then ejected 'inferred'); red means recurse into the
    first half and still test the second. A single candidate red alone is
    'ejected: red', its last 20 output lines in a file.
 6. The survivors are joined and verified again unless that exact set already
    passed. Red there although every member passed in a group: find the smallest
    red prefix by halving, name the minimal failing set, eject the LATER member
    as 'interaction', repeat. A tree never verified green never lands.
 7. Recovery (default; --no-recover disables it): for each member ejected
    'inferred', in input order, verify (landed set + that member, input order)
    once. Green: the member JOINS and that set is the verified landed set. Red:
    it stays ejected, now PROVEN (the 'inferred' flag is dropped; with a
    non-empty landed set the record gains "red_with": the landed set, because
    only "red together with them" was run, never the member alone). Cost: one run per inferred
    member, counted in 'runs'.
 8. Delivery (only with --keep, only after the final green verification): the landed
    commits are packed in the private repository (`pack-objects --revs --stdout`),
    stored in yours (`index-pack --stdin`) and the branch is created with
    `update-ref refs/heads/NAME SHA ""` (create-only: an existing name is never
    touched). No transport, no URL handling, no hooks. If delivery fails the exit is 2,
    the JSON says "delivery_error" with the verified "commit", and the private root is
    KEPT (its path is printed) so the result is not lost; objects already stored in
    yours stay as unreachable garbage, no ref is left.
 With --state the next window is +1 after a batch landed whole on its first run,
 halved (min 1) after any red, unchanged when only conflicts/empties/unrelated/
 unrepresentable were ejected; a state file that is unreadable, not an integer in
 1..64, or Infinity / NaN is ignored with a one-line warning and the window is
 --max-batch. A --state that is a directory or sits in an unwritable directory is exit
 2 at the start; the file is replaced atomically (temp file + rename).
Environment: EVERY git call is `git -c K=V... (--git-dir=PRIVATE | -C DIR) ...` with a
sanitised environment (all GIT_* removed except GIT_EXEC_PATH; HOME and XDG_CONFIG_HOME
point to an empty directory; GIT_CONFIG_NOSYSTEM=1, GIT_CONFIG_GLOBAL=/dev/null;
GIT_NO_LAZY_FETCH=1; stdin /dev/null; fixed committer identity) and a command-line -c set
(hooks off, fsmonitor off, no signing, no autocrlf, no gc) as a second layer. The only
calls that run with -C <your repo> are: one rev-parse for the object format, the objects
directory and shallowness; one config --get-regexp for the partial-clone check; one
rev-parse --verify per name; and, at delivery, index-pack --stdin, update-ref, rev-parse
and cat-file on --git-dir=<your common git directory> (index-pack run from a subdirectory
would create a stray .git there). None of them executes a configured program. The VERIFY command gets the
caller's environment minus every repo-pointing variable (`git rev-parse
--local-env-vars` plus a hard-coded superset, GIT_CONFIG*, GIT_AUTHOR_*, GIT_COMMITTER_*),
PWD set to its worktree. If GIT_DIR or GIT_WORK_TREE is set and --repo is not given the
tool refuses (exit 2): pass --repo.
Limits: verify output goes to a file; only the last 64 KiB / 20 lines are kept in memory;
--flaky-rerun regexes match LINE BY LINE over the file (never across lines; a line longer
than 64 KiB is matched in 64 KiB pieces).
Exit: 0 all admitted landed, 1 something ejected, 2 usage/git/delivery/unexpected error,
      3 nothing was verified, 128+N after SIGHUP/SIGINT/SIGTERM (129/130/143). The last
      stdout line is one JSON object; on an unexpected exception it carries "error".
"""


class Fatal(Exception):
    pass


MIN_GIT = (2, 31)
BATCH_CAP = 64
TAIL_BYTES = 65536
TAIL_LINES = 20
TIMEOUT_CAP = 7 * 86400
IDENT_NAME = "integration-train"
IDENT_EMAIL = "train@localhost"
SIGS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
QUIET = ("conflict", "empty", "unrelated", "unrepresentable-on-this-filesystem")
STALE_SECONDS = 86400
UNREP = "unrepresentable-on-this-filesystem"

# Variables that change which repository / index / object store git uses, plus the
# ones that inject configuration or identity. `git rev-parse --local-env-vars` is
# queried at run time and unioned with this hard-coded superset.
LOCAL_ENV_SUPERSET = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX",
    "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_GRAFT_FILE",
    "GIT_SHALLOW_FILE", "GIT_IMPLICIT_WORK_TREE", "GIT_QUARANTINE_PATH",
    "GIT_REPLACE_REF_BASE", "GIT_NO_REPLACE_OBJECTS", "GIT_INDEX_VERSION",
    "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_ATTR_SOURCE",
    "GIT_EXTERNAL_DIFF", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_PAGER",
)

# The second layer: the -c set on EVERY git call (the private config already says the same).
GIT_C = (
    "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.untrackedCache=false",
    "core.autocrlf=false", "core.attributesFile=/dev/null", "core.excludesFile=/dev/null",
    "core.sparseCheckout=false", "core.splitIndex=false", "core.pager=cat",
    "core.editor=true", "commit.gpgsign=false", "tag.gpgsign=false", "gc.auto=0",
    "maintenance.auto=false", "rerere.enabled=false", "submodule.recurse=false",
    "advice.detachedHead=false", "log.showSignature=false", "merge.verifySignatures=false",
    "protocol.allow=never",
)


class JoinFail(Exception):
    def __init__(self, cid, squash=False, empty=False):
        Exception.__init__(self, cid)
        self.squash = squash
        self.empty = empty


class Cand:
    def __init__(self, cid):
        self.id = cid
        self.tip = None
        self.kind = "pick"
        self.paths = set()
        self.added = set()
        self.deleted = set()
        self.message = ""
        self.author = {}
        self.subjects = []


def nul_names(text):
    return set(n for n in text.split("\0") if n)


def force_remove(path):
    """Remove `path` entirely: first make every directory under it owner-traversable (never
    following a symlink), then rmtree; retried once. A symlink is unlinked, never entered."""
    for _ in (0, 1):
        if os.path.islink(path) or not os.path.isdir(path):
            try:
                os.unlink(path)
            except OSError:
                pass
        else:
            try:
                os.chmod(path, 0o700)
            except OSError:
                pass
            for root, dirs, _files in os.walk(path, followlinks=False):
                for d in dirs:
                    full = os.path.join(root, d)
                    if not os.path.islink(full):
                        try:
                            os.chmod(full, 0o700)
                        except OSError:
                            pass
            shutil.rmtree(path, ignore_errors=True)
        if not os.path.lexists(path):
            return


def stale_notice():
    """One line when an earlier SIGKILLed run left an itrain-* directory older than a day."""
    base = tempfile.gettempdir()
    try:
        old = [n for n in os.listdir(base) if n.startswith("itrain-")
               and time.time() - os.lstat(os.path.join(base, n)).st_mtime > STALE_SECONDS]
    except OSError:
        return
    if old:
        print("notice: %d stale itrain-* director%s older than a day in %s (left by a killed run; "
              "this tool never deletes them)" % (len(old), "y" if len(old) == 1 else "ies", base),
              file=sys.stderr)


class Train:
    def __init__(self, a):
        self.a = a
        self.repo = os.path.abspath(a.repo)
        self.tmp = None  # the private root P, set (signals blocked) before anything lives in it
        self.priv = None
        self.cgit = None  # the caller's common git directory (delivery only)
        self.uid = ""
        self.worktrees = []  # parent directories w<k>
        self.keep_root = False
        self.cleaned = False
        self.n_exec = 0
        self.n_wt = 0
        self.runs = 0
        self.runs_per = {}
        self.cache = {}
        self.commits = {}
        self.last_red = {}
        self.cands = {}
        self.ejected = []
        self.deferred = []
        self.patterns = []
        self.genv = {}
        self.venv = {}
        self.cflags = []
        self.fold = None
        self.names = {}
        self.base_sha = ""

    # ---- plumbing -------------------------------------------------------
    def make_root(self):
        old = signal.pthread_sigmask(signal.SIG_BLOCK, set(SIGS))
        try:
            self.tmp = tempfile.mkdtemp(prefix="itrain-")
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old)
        self.uid = os.path.basename(self.tmp)
        self.priv = os.path.join(self.tmp, "repo.git")

    def build_env(self):
        base = dict(os.environ)
        home = os.path.join(self.tmp, "home")
        os.makedirs(home, exist_ok=True)
        self.genv = {k: v for k, v in base.items() if not k.startswith("GIT_") or k == "GIT_EXEC_PATH"}
        self.genv.update({
            "HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_EDITOR": "true", "GIT_NO_LAZY_FETCH": "1",
            "GIT_COMMITTER_NAME": IDENT_NAME, "GIT_COMMITTER_EMAIL": IDENT_EMAIL})
        drop = set(LOCAL_ENV_SUPERSET)
        try:
            p = subprocess.run(["git", "rev-parse", "--local-env-vars"], cwd=self.tmp,
                               capture_output=True, text=True, env=self.genv,
                               stdin=subprocess.DEVNULL)
            if p.returncode == 0:
                drop.update(x.strip() for x in p.stdout.split("\n") if x.strip().startswith("GIT_"))
        except OSError as e:
            raise Fatal("cannot run git: %s" % e)
        self.venv = {k: v for k, v in base.items()
                     if k not in drop and not k.startswith(("GIT_CONFIG", "GIT_AUTHOR_", "GIT_COMMITTER_"))}
        self.venv.pop("OLDPWD", None)
        self.cflags = []
        for kv in GIT_C:
            self.cflags += ["-c", kv]

    def git(self, sub, *args, input=None, env=None, ok=(0,), cwd=None, caller=False,
            stdin=None, stdout=None):
        """Run git. Default: in the PRIVATE repository (--git-dir). cwd=DIR runs in a private
        worktree; caller=True is the one door into the caller's repository (see EPILOG)."""
        e = dict(self.genv)
        if env:
            e.update(env)
        if cwd:
            loc = ["-C", cwd]
        elif caller == "gitdir":  # delivery: the common git directory, never a discovered one
            loc = ["--git-dir=" + self.cgit]
        elif caller:
            loc = ["-C", self.repo]
        else:
            loc = ["--git-dir=" + self.priv]
        cmd = ["git"] + self.cflags + loc + [sub] + list(args)
        kw = {"cwd": self.tmp, "env": e, "stderr": subprocess.PIPE, "text": True,
              "encoding": "utf-8", "errors": "surrogateescape"}
        kw["stdout"] = stdout if stdout is not None else subprocess.PIPE
        if input is not None:
            kw["stdin"] = subprocess.PIPE
            kw["input"] = input
        else:
            kw["stdin"] = stdin if stdin is not None else subprocess.DEVNULL
        # own process group: a signal that unwinds us kills the WHOLE group (`git worktree add`
        # runs a child that keeps writing the tree after its parent is killed)
        popen_kw = {k: v for k, v in kw.items() if k != "input"}
        proc = subprocess.Popen(cmd, start_new_session=True, **popen_kw)
        try:
            out, err = proc.communicate(kw.get("input"))
        except BaseException:
            self.kill_group(proc)
            proc.wait()
            raise
        p = subprocess.CompletedProcess(cmd, proc.returncode, out, err)
        if p.returncode not in ok:
            first = (p.stderr.strip().split("\n") or [""])[0][:200]
            raise Fatal("git %s failed (exit %d): %s" % (sub, p.returncode, first))
        return p

    def check_git_version(self):
        try:
            out = subprocess.run(["git", "--version"], capture_output=True, text=True,
                                 env=self.genv, cwd=self.tmp, stdin=subprocess.DEVNULL).stdout
        except OSError as e:
            raise Fatal("cannot run git: %s" % e)
        m = re.search(r"(\d+)\.(\d+)", out)
        if not m:
            raise Fatal("cannot parse git version from %r" % out.strip()[:60])
        found = (int(m.group(1)), int(m.group(2)))
        if found < MIN_GIT:
            raise Fatal("git %d.%d found, %d.%d or newer required" % (found + MIN_GIT))

    def probe_caller(self):
        """Read-only facts about the caller: one rev-parse, one config read."""
        try:
            p = self.git("rev-parse", "--is-shallow-repository", "--show-object-format",
                         "--path-format=absolute", "--git-path", "objects", "--git-common-dir",
                         caller=True)
        except Fatal:
            raise Fatal("--repo %s is not a git repository" % self.a.repo)
        lines = p.stdout.split("\n")
        if len(lines) < 4 or not lines[2] or not lines[3]:
            raise Fatal("--repo %s: cannot read the object directory" % self.a.repo)
        shallow, fmt, objdir = lines[0].strip(), lines[1].strip(), lines[2]
        self.cgit = lines[3]
        if shallow == "true":
            raise Fatal("--repo %s is a shallow clone: refused (history would be missing)" % self.a.repo)
        if fmt not in ("sha1", "sha256") or "\n" in objdir or not os.path.isdir(objdir):
            raise Fatal("--repo %s: unsupported object format or directory (%s)" % (self.a.repo, fmt))
        q = self.git("config", "--get-regexp", r"^(extensions\.partialclone|remote\..*\.promisor)$",
                     ok=(0, 1), caller=True)
        for ln in q.stdout.split("\n"):
            key, _, val = ln.partition(" ")
            if key.startswith("extensions.") or (key and val.strip().lower() in ("", "true", "yes", "on", "1")):
                raise Fatal("--repo %s is a partial clone (%s): refused, a missing object must be an "
                            "error, never a fetch" % (self.a.repo, key))
        return fmt, objdir

    def resolve_all(self, refs):
        """One rev-parse --verify per name, in the caller, once; ids from then on."""
        out = []
        for r in refs:
            p = self.git("rev-parse", "--verify", "--end-of-options", r + "^{commit}", ok=(0, 128),
                         caller=True)
            sha = p.stdout.strip()
            if p.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
                raise Fatal("does not resolve: %s" % r)
            out.append(sha)
        return out

    def init_private(self, fmt, objdir):
        """A fresh bare repository whose config this tool writes: nothing of the caller's is loaded."""
        self.git("init", "--bare", "--quiet", "--template=", "--object-format=" + fmt, self.priv,
                 cwd=self.tmp)
        cfg = os.path.join(self.priv, "config")
        keep = []
        q = self.git("config", "--file", cfg, "--get-regexp",
                     r"^core\.(filemode|ignorecase|precomposeunicode|symlinks)$", ok=(0, 1), cwd=self.tmp)
        for ln in q.stdout.split("\n"):
            k, _, v = ln.partition(" ")
            if k:
                keep.append("\t%s = %s\n" % (k.split(".", 1)[1], v))
        text = ("[core]\n\trepositoryformatversion = %d\n\tbare = true\n\thooksPath = /dev/null\n"
                "\tautocrlf = false\n\tfsmonitor = false\n\tlogAllRefUpdates = false\n%s"
                "[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n[commit]\n\tgpgsign = false\n"
                "[log]\n\tshowSignature = false\n[merge]\n\tverifySignatures = false\n"
                "[protocol]\n\tallow = never\n"
                % (1 if fmt == "sha256" else 0, "".join(keep)))
        if fmt == "sha256":
            text += "[extensions]\n\tobjectformat = sha256\n"
        with open(cfg, "w") as fh:
            fh.write(text)
        info = os.path.join(self.priv, "objects", "info")
        os.makedirs(info, exist_ok=True)
        with open(os.path.join(info, "alternates"), "w") as fh:
            fh.write(objdir + "\n")

    def probe_fs(self):
        """Does the filesystem under the private root fold case / Unicode form?"""
        def present(make, look):
            a, b = os.path.join(self.tmp, make), os.path.join(self.tmp, look)
            with open(a, "w"):
                pass
            try:
                return os.path.lexists(b)
            finally:
                os.unlink(a)
        case = present("fsprobe-a", "fsprobe-A")
        nfc = present("fsprobe-é", "fsprobe-é")
        return (case, nfc) if (case or nfc) else None

    def fold_key(self, path):
        k = unicodedata.normalize("NFD", path) if self.fold[1] or self.fold[0] else path
        return k.lower() if self.fold[0] else k

    def new_worktree(self, commit):
        self.n_wt += 1
        parent = os.path.join(self.tmp, "w%d" % self.n_wt)
        self.worktrees.append(parent)  # registered before it exists: cleanup covers it
        os.mkdir(parent)
        tree = os.path.join(parent, "tree")
        self.git("worktree", "add", "--quiet", "--detach", tree, commit)
        return tree

    def drop_worktree(self, wt):
        parent = os.path.dirname(wt)
        force_remove(parent)
        if parent in self.worktrees:
            self.worktrees.remove(parent)

    def assert_clean(self, wt, commit):
        """One call: HEAD is `commit` and `status --porcelain --ignored` lists nothing."""
        out = self.git("status", "--porcelain=v2", "--branch", "--ignored", "--untracked-files=all",
                       "-z", cwd=wt).stdout
        entries = [x for x in out.split("\0") if x]
        head = ""
        rest = []
        for x in entries:
            if x.startswith("# branch.oid "):
                head = x[len("# branch.oid "):]
            elif not x.startswith("# "):
                rest.append(x)
        if head != commit or rest:
            raise Fatal("temporary worktree is not byte-clean at %s (head %s, status %r)"
                        % (commit[:12], head[:12], (rest or [""])[0][:80]))

    def apply(self, wt, c):
        """Join candidate c onto the HEAD of the temp worktree wt; return the new HEAD."""
        if c.kind == "pick":
            p = self.git("cherry-pick", c.tip, ok=(0, 1), cwd=wt)
            if p.returncode == 1:
                unmerged = self.git("ls-files", "-u", cwd=wt).stdout
                staged = self.git("diff", "--cached", "--quiet", ok=(0, 1), cwd=wt).returncode
                self.git("cherry-pick", "--abort", cwd=wt)
                raise JoinFail(c.id, empty=(not unmerged and staged == 0))
        else:
            p = self.git("merge", "--squash", c.tip, ok=(0, 1), cwd=wt)
            if p.returncode == 1:
                raise JoinFail(c.id, squash=True)
            if self.git("diff", "--cached", "--quiet", ok=(0, 1), cwd=wt).returncode == 0:
                raise JoinFail(c.id, squash=True, empty=True)
            self.git("commit", "-q", "--no-verify", "-F", "-", input=c.message, env=c.author, cwd=wt)
        return self.git("rev-parse", "HEAD", cwd=wt).stdout.strip()

    def on_signal(self, signum, frame):
        sys.exit(128 + signum)

    def cleanup(self):
        if self.cleaned:
            return
        self.cleaned = True
        for sig in SIGS:
            signal.signal(sig, signal.SIG_IGN)
        if self.tmp is None:
            return
        if self.keep_root:  # everything but the private repository holding the verified result
            for n in os.listdir(self.tmp):
                if n != "repo.git":
                    force_remove(os.path.join(self.tmp, n))
            return
        force_remove(self.tmp)

    # ---- admission ------------------------------------------------------
    def describe(self, c, base_sha):
        """Fill c from git; 'ok', 'empty' (no commit beyond the base) or 'unrelated'."""
        revs = [ln.split() for ln in self.git("rev-list", "--parents", "--reverse", c.tip,
                                              "^" + base_sha).stdout.split("\n") if ln.strip()]
        if not revs:
            return "empty"
        if self.git("merge-base", base_sha, c.tip, ok=(0, 1)).returncode == 1:
            return "unrelated"
        toks = self.git("diff", "--name-status", "-z", "--no-renames",
                        base_sha + "..." + c.tip).stdout.split("\0")
        net = set()
        for i in range(0, len(toks) - 1, 2):
            st, path = toks[i], toks[i + 1]
            net.add(path)
            if st.startswith("A"):
                c.added.add(path)
            elif st.startswith("D"):
                c.deleted.add(path)
        per = nul_names(self.git("log", "-z", "--format=", "--name-only", "--no-renames", "-m",
                                 c.tip, "^" + base_sha).stdout)
        c.net = bool(net)
        c.paths = net | per
        if len(revs) == 1 and len(revs[0]) == 2:
            c.kind = "pick"
            c.author = {}
        else:
            subjects = self.git("log", "-z", "--reverse", "--format=%s", c.tip,
                                "^" + base_sha).stdout.split("\0")
            c.subjects = [x for x in subjects if x != ""]
            c.kind = "squash"
            c.message = "%s\n\n%s\n" % (c.id, "\n".join("- " + x for x in c.subjects))
            who = self.git("log", "-1", "--format=%an%n%ae%n%aI", c.tip).stdout.split("\n")
            c.author = {"GIT_AUTHOR_NAME": who[0] or IDENT_NAME,
                        "GIT_AUTHOR_EMAIL": who[1] if len(who) > 1 and who[1] else IDENT_EMAIL}
            if len(who) > 2 and who[2]:
                c.author["GIT_AUTHOR_DATE"] = who[2]
        return "ok"

    def load_names(self):
        """Folded names of the base tree; a base that collides with itself is exit 2."""
        self.fold = self.probe_fs()
        if not self.fold:
            return
        out = self.git("ls-tree", "-r", "-z", "--name-only", self.base_sha).stdout
        for p in out.split("\0"):
            if not p:
                continue
            k = self.fold_key(p)
            if k in self.names and self.names[k] != p:
                raise Fatal("the base itself holds paths this filesystem cannot tell apart: %r and %r"
                            % (self.names[k], p))
            self.names[k] = p

    def collision(self, c):
        """The first path c adds that this filesystem cannot keep apart from one already there."""
        if not self.fold:
            return None
        gone = set(self.fold_key(p) for p in c.deleted)
        adds = {}
        for p in sorted(c.added):
            k = self.fold_key(p)
            for other in (adds.get(k), None if k in gone else self.names.get(k)):
                if other is not None and other != p:
                    return "adds %r which collides with %r" % (p, other)
            adds[k] = p
        return None

    def admit(self, base_sha, window):
        batch = []
        owner = {}
        wt = None
        last = base_sha
        self.load_names()
        for cid in self.a.candidates:
            c = self.cands[cid]
            st = self.describe(c, base_sha)
            if st == "empty":
                self.eject(cid, "empty", ["no commits beyond the base"])
                continue
            if st == "unrelated":
                self.eject(cid, "unrelated", ["no common ancestor with the base"])
                continue
            if not c.net:
                self.eject(cid, "empty", ["no net change beyond the base"])
                continue
            hit = None
            for path in sorted(c.paths):
                if path in owner:
                    hit = (owner[path], path)
                    break
            if hit:
                self.deferred.append({"id": cid, "why": "overlaps %s on %s" % hit})
                continue
            if len(batch) >= window:
                self.deferred.append({"id": cid, "why": "batch full"})
                continue
            clash = self.collision(c)
            if clash:
                self.eject(cid, UNREP, [clash])
                continue
            if wt is None:
                wt = self.new_worktree(base_sha)
            try:
                sha = self.apply(wt, c)
            except JoinFail as e:
                if e.squash:
                    self.drop_worktree(wt)
                    wt = self.new_worktree(last)
                if e.empty:
                    self.eject(cid, "empty", ["no net change on the base"])
                else:
                    self.eject(cid, "conflict", ["does not apply cleanly on the joined tree"])
                continue
            batch.append(cid)
            self.commits[tuple(batch)] = sha
            last = sha
            for path in c.paths:
                owner[path] = cid
            if self.fold:
                for p in c.deleted:
                    self.names.pop(self.fold_key(p), None)
                for p in c.added:
                    self.names[self.fold_key(p)] = p
        if wt is not None:
            self.drop_worktree(wt)
        return batch

    def eject(self, cid, why, tail, extra=None):
        log = ""
        if tail:
            os.makedirs(self.a.log_dir, exist_ok=True)
            log = os.path.join(self.a.log_dir, "%s-%s.log" % (self.uid, re.sub(r"[^A-Za-z0-9_.-]", "_", cid)))
            with open(log, "w") as fh:
                fh.write("\n".join(tail[-TAIL_LINES:]) + "\n")
        rec = {"id": cid, "why": why, "log": log}
        if extra:
            rec.update(extra)
        self.ejected.append(rec)
        print("ejected: %s (%s)%s%s" % (cid, why, " inferred" if extra and extra.get("inferred") else "",
                                        " log=" + log if log else ""))

    # ---- join -----------------------------------------------------------
    def kill_group(self, p):
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def tail_of(self, path):
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            data = fh.read()
        lines = data.decode("utf-8", "replace").rstrip("\n").split("\n")
        if size > TAIL_BYTES and len(lines) > 1:
            lines = lines[1:]  # the first line is cut mid-way
        return lines[-TAIL_LINES:]

    def flaky_match(self, path):
        """First known-flaky pattern found in the log, streamed line by line (bounded memory)."""
        with open(path, "rb") as fh:
            while True:
                raw = fh.readline(TAIL_BYTES)
                if not raw:
                    return None
                line = raw.decode("utf-8", "replace")
                for r in self.patterns:
                    if r.search(line):
                        return r.pattern

    def exec_once(self, wt, ids):
        self.n_exec += 1
        self.runs += 1
        for i in ids:
            self.runs_per[i] = self.runs_per.get(i, 0) + 1
        out = os.path.join(self.tmp, "out%d.log" % self.n_exec)
        vtmp = os.path.join(os.path.dirname(wt), "tmp")  # this run's own TMPDIR, removed with it
        os.mkdir(vtmp)
        t0 = time.time()
        reason = None
        env = dict(self.venv)
        env["PWD"] = wt
        env["TMPDIR"] = vtmp
        with open(out, "w") as fh:
            p = subprocess.Popen(self.a.verify, shell=True, cwd=wt, stdout=fh, env=env,
                                 stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True)
            try:
                try:
                    rc = p.wait(timeout=self.a.verify_timeout)
                except subprocess.TimeoutExpired:
                    reason = "timeout"
                    self.kill_group(p)
                    rc = p.wait()
            finally:
                self.kill_group(p)
                p.poll()
        dt = time.time() - t0
        tail = self.tail_of(out)
        ok = rc == 0 and reason is None
        if reason == "timeout":
            tail = (tail + ["TIMEOUT after %ss" % self.a.verify_timeout])[-TAIL_LINES:]
        print("run %d: [%s] %s %.2fs" % (self.runs, ",".join(ids), "green" if ok else
                                         "red (%s)" % (reason or "exit %d" % rc), dt))
        return ok, tail, reason, out

    def run_clean(self, sha, ids):
        """One verify run in a brand-new worktree at exactly `sha`, asserted byte-clean."""
        wt = self.new_worktree(sha)
        try:
            self.assert_clean(wt, sha)
            return self.exec_once(wt, ids)
        finally:
            self.drop_worktree(wt)

    def join(self, ids):
        """The commit holding base + ids (input order), joined in a temp worktree."""
        k = len(ids)
        while k > 0 and tuple(ids[:k]) not in self.commits:
            k -= 1
        if k == len(ids):
            return self.commits[tuple(ids)]
        start = self.commits[tuple(ids[:k])] if k else self.base_sha
        wt = self.new_worktree(start)
        try:
            for j in range(k, len(ids)):
                sha = self.apply(wt, self.cands[ids[j]])
                self.commits[tuple(ids[:j + 1])] = sha
        finally:
            self.drop_worktree(wt)
        return self.commits[tuple(ids)]

    def verify(self, ids):
        key = tuple(ids)
        if key in self.cache:
            return self.cache[key][0]
        try:
            sha = self.join(ids)
        except JoinFail as e:
            res = (False, ["join conflict applying %s" % e], "conflict")
            self.cache[key] = res
            for i in ids:
                self.last_red[i] = res[1:]
            return False
        ok, tail, reason, log = self.run_clean(sha, ids)
        if not ok and reason is None and self.a.flaky_rerun:
            matched = self.flaky_match(log)
            if matched is not None:
                print("rerun: matched %s" % matched)
                os.unlink(log)
                ok, tail, reason, log = self.run_clean(sha, ids)
        os.unlink(log)
        self.cache[key] = (ok, tail, reason)
        if not ok:
            for i in ids:
                self.last_red[i] = (tail, reason)
        return ok

    # ---- bisection ------------------------------------------------------
    def bisect(self, items, mode):
        """mode: u unknown, p red just proven by a run, i red inferred (run skipped)."""
        if mode == "u":
            if self.verify(items):
                return list(items), []
            mode = "p"
        if len(items) == 1:
            tail, reason = self.last_red.get(items[0], ([], None))
            extra = {"inferred": True} if mode == "i" else None
            self.eject(items[0], reason or "red", tail, extra)
            return [], list(items)
        if mode == "i":
            print("skip: own run of [%s] (second half known red)" % ",".join(items))
        h = (len(items) + 1) // 2
        first, second = items[:h], items[h:]
        g1, b1 = self.bisect(first, "u")
        mode2 = "i" if not b1 else "u"
        g2, b2 = self.bisect(second, mode2)
        return g1 + g2, b1 + b2

    def final_join(self, survivors):
        survivors = list(survivors)
        while survivors:
            ok = self.verify(survivors)
            if ok:
                return survivors
            if len(survivors) == 1:
                tail, reason = self.cache[tuple(survivors)][1:]
                self.eject(survivors[0], reason or "red", tail)
                return []
            lo, hi = 1, len(survivors)
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if self.verify(survivors[:mid]):
                    lo = mid
                else:
                    hi = mid
            m = survivors[hi - 1]
            core = list(survivors[:hi - 1])
            for e in list(core):
                trial = [x for x in core if x != e] + [m]
                if not self.verify(trial):
                    core = [x for x in core if x != e]
            tail = self.cache[tuple(core + [m])][1]
            if core:
                print("interaction: %s fails together with %s; ejecting the later one (%s)"
                      % (m, ",".join(core), m))
                self.eject(m, "interaction", tail, {"with": core})
            else:
                self.eject(m, "red", tail)
            survivors = [x for x in survivors if x != m]
        return survivors

    def recover(self, landed):
        """Give every member ejected 'inferred' one verified chance to join the landed set."""
        if self.a.no_recover:
            return landed
        order = {cid: i for i, cid in enumerate(self.a.candidates)}
        for rec in sorted([e for e in self.ejected if e.get("inferred")], key=lambda e: order[e["id"]]):
            trial = sorted(landed + [rec["id"]], key=lambda x: order[x])
            if self.verify(trial):
                landed = trial
                self.ejected.remove(rec)
                print("recovered: %s joins the landed set (verified green together)" % rec["id"])
            elif self.cache[tuple(trial)][2] == "conflict":
                print("recover: %s does not join the landed set; stays ejected (inferred)" % rec["id"])
            else:
                # red WITH the landed set is proven; red alone is not (no run of it alone
                # exists), so a non-empty landed set is recorded as "red_with"
                rec.pop("inferred", None)
                if landed:
                    rec["red_with"] = list(landed)
                print("proven: %s is red together with the landed set" % rec["id"])
        return landed

    # ---- driver ---------------------------------------------------------
    def read_state(self):
        d = self.a.max_batch
        if not self.a.state or not os.path.exists(self.a.state):
            return d
        try:
            with open(self.a.state) as fh:
                n = json.load(fh)["next"]
            if type(n) is not int or not 1 <= n <= BATCH_CAP:
                raise ValueError("next=%r is not an integer in 1..%d" % (n, BATCH_CAP))
            return n
        except (ValueError, KeyError, TypeError, OSError, RecursionError) as e:
            print("warning: ignoring --state %s (%s); window reset to %d"
                  % (self.a.state, str(e).split("\n")[0][:80], d), file=sys.stderr)
            return d

    def check_state_path(self):
        """A --state that cannot be written is exit 2 at the START, never after a verified batch."""
        s = self.a.state
        if not s:
            return
        if os.path.isdir(s):
            raise Fatal("--state %s is a directory" % s)
        try:
            fd, probe = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(s)), prefix=".state-probe")
            os.close(fd)
            os.unlink(probe)
        except OSError as e:
            raise Fatal("--state %s is not writable: %s" % (s, e.strerror or e))

    def write_state(self, window, admitted, bad, first_green, clean):
        if not self.a.state:
            return
        if first_green:
            nxt = window + 1 if clean else window
        else:
            nxt = window // 2
        nxt = min(BATCH_CAP, max(1, nxt))
        doc = {"next": nxt, "window": window, "last_p": bad / float(admitted),
               "last_runs": self.runs, "admitted": admitted}
        tmpf = None
        try:  # temp file in the same directory, then one rename: never a half-written state
            fd, tmpf = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(self.a.state)),
                                        prefix=os.path.basename(self.a.state) + ".tmp")
            with os.fdopen(fd, "w") as fh:
                json.dump(doc, fh, separators=(",", ":"))
            os.replace(tmpf, self.a.state)
        except OSError as e:
            print("warning: cannot write --state %s: %s" % (self.a.state, e.strerror or e), file=sys.stderr)
            if tmpf and os.path.lexists(tmpf):
                os.unlink(tmpf)

    def deliver(self, sha):
        """The only write to the caller: objects (index-pack --stdin), then one create-only ref."""
        branch = "train-%s-%s" % (self.uid, secrets.token_hex(4))
        packf = os.path.join(self.tmp, "delivery.pack")
        with open(packf, "wb") as fh:
            self.git("pack-objects", "--revs", "--stdout", "-q", input="%s\n^%s\n" % (sha, self.base_sha),
                     stdout=fh)
        with open(packf, "rb") as fh:
            self.git("index-pack", "--stdin", caller="gitdir", stdin=fh)
        self.git("update-ref", "refs/heads/" + branch, sha, "", caller="gitdir")  # "" = must not exist
        got = self.git("rev-parse", "--verify", "refs/heads/" + branch, caller="gitdir").stdout.strip()
        if got != sha:
            raise Fatal("branch %s does not point at %s" % (branch, sha[:12]))
        self.git("cat-file", "-e", sha + "^{tree}", caller="gitdir")
        return branch

    def run(self):
        if self.a.flaky_rerun:
            try:
                with open(self.a.flaky_rerun) as fh:
                    pats = [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
                self.patterns = [re.compile(x) for x in pats]
            except OSError as e:
                raise Fatal("cannot read --flaky-rerun file: %s" % e)
            except re.error as e:
                raise Fatal("bad regex in --flaky-rerun file: %s" % e)
        self.check_state_path()
        if not os.path.isdir(self.repo):
            raise Fatal("--repo %s is not a directory" % self.a.repo)
        stale_notice()
        self.make_root()
        self.build_env()
        self.check_git_version()
        fmt, objdir = self.probe_caller()
        refs = [self.a.base] + list(self.a.candidates)
        shas = self.resolve_all(refs)
        self.base_sha = shas[0]
        seen = {}
        for cid, sha in zip(self.a.candidates, shas[1:]):
            if sha in seen:
                raise Fatal("candidates %s and %s are the same commit" % (seen[sha], cid))
            seen[sha] = cid
            self.cands[cid] = Cand(cid)
            self.cands[cid].tip = sha
        self.init_private(fmt, objdir)
        cmds = ["create refs/itrain/base %s\n" % self.base_sha]
        cmds += ["create refs/itrain/cand/%d %s\n" % (i + 1, s) for i, s in enumerate(shas[1:])]
        self.git("update-ref", "--stdin", input="".join(cmds))
        window = self.read_state()
        batch = self.admit(self.base_sha, window)
        landed = []
        branch = ""
        commits = {}
        failure = ""
        final = ""
        if batch:
            print("batch: %d admitted (window %d): %s" % (len(batch), window, ",".join(batch)))
            if self.verify(batch):
                good = list(batch)
            else:
                good, _ = self.bisect(batch, "p")
            landed = self.final_join(good)
            landed = self.recover(landed)
            if landed:
                for k in range(1, len(landed) + 1):
                    commits[landed[k - 1]] = self.commits[tuple(landed[:k])]
                final = self.commits[tuple(landed)]
                if self.a.keep:
                    try:
                        branch = self.deliver(final)
                    except Fatal as e:
                        failure = str(e)
                        self.keep_root = True
            reds = [e for e in self.ejected if e["why"] not in QUIET]
            quiet = [e for e in self.ejected if e["why"] in QUIET]
            first_green = self.runs == 1 and not reds and landed == batch
            self.write_state(window, len(batch), len(reds), first_green, not quiet)
        for d in self.deferred:
            print("deferred: %s: %s" % (d["id"], d["why"]))
        for cid in landed:
            print("landed: %s %s" % (cid, commits[cid]))
        if branch:
            print("integration branch: %s" % branch)
        elif landed and not failure:
            print("nothing was written to your repository (use --keep to deliver the landed branch)")
        print("runs: %d (per candidate: %s)" % (
            self.runs, " ".join("%s=%d" % (k, v) for k, v in self.runs_per.items())))
        print("batch: %d" % len(batch))
        summary = {"landed": landed, "ejected": self.ejected, "deferred": self.deferred,
                   "runs": self.runs, "batch": len(batch), "branch": branch,
                   "commits": commits, "runs_per": self.runs_per}
        if failure:
            summary.update({"delivery_error": failure, "commit": final, "private_root": self.tmp})
            print("error: verified but NOT delivered: %s; commit %s is in the private repository %s"
                  " (kept)" % (failure, final, self.priv), file=sys.stderr)
        print(json.dumps(summary, separators=(",", ":")))
        sys.stdout.flush()
        if failure:
            return 2
        if self.runs == 0:
            return 3
        return 1 if self.ejected else 0


def _positive_float(s):
    try:
        v = float(s)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % s)
    if not math.isfinite(v) or v <= 0 or v > TIMEOUT_CAP:
        raise argparse.ArgumentTypeError("must be a number in (0, %d] seconds, got %r" % (TIMEOUT_CAP, s))
    return v


def _batch_size(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("not an integer: %r" % s)
    if not 1 <= v <= BATCH_CAP:
        raise argparse.ArgumentTypeError("must be an integer in 1..%d, got %r" % (BATCH_CAP, s))
    return v


def parse(argv):
    ap = argparse.ArgumentParser(
        prog="integration-train.py",
        description="Verify an ordered batch of candidate branches ONCE on their joined tree; "
                    "bisect by halving on red. Never pushes, merges or touches a remote.",
        epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, help="base ref the batch is joined onto")
    ap.add_argument("--verify", required=True, metavar="CMD",
                    help="shell command run in the joined worktree; exit 0 = green")
    ap.add_argument("--max-batch", type=_batch_size, default=4,
                    help="window size when no --state, 1..%d (default 4)" % BATCH_CAP)
    ap.add_argument("--state", metavar="FILE", help="adaptive-window state file (JSON)")
    ap.add_argument("--flaky-rerun", metavar="FILE",
                    help="file of regexes of KNOWN flaky tests; a red whose output matches one "
                         "(line by line) is re-run once")
    ap.add_argument("--verify-timeout", type=_positive_float, default=None, metavar="SECONDS",
                    help="kill the verify process group after SECONDS (> 0); counts as red 'timeout'")
    ap.add_argument("--no-recover", action="store_true",
                    help="do not re-verify members ejected 'inferred' together with the landed set")
    ap.add_argument("--keep", action="store_true",
                    help="deliver the landed commits as ONE new branch in your repository (the only "
                         "write; without it nothing is written)")
    ap.add_argument("--repo", default=None,
                    help="repository or worktree (default: cwd; required when GIT_DIR or "
                         "GIT_WORK_TREE is set)")
    ap.add_argument("--log-dir", default=os.path.join(tempfile.gettempdir(), "integration-train-logs"),
                    help="where ejected candidates' last 20 output lines are saved")
    ap.add_argument("candidates", nargs="+", metavar="CAND", help="ordered branches or commits")
    a = ap.parse_args(argv)
    for i, c in enumerate(a.candidates):
        if c in a.candidates[:i]:
            ap.error("candidate given twice: %s" % c)
    if a.repo is None:
        if "GIT_DIR" in os.environ or "GIT_WORK_TREE" in os.environ:
            ap.error("GIT_DIR / GIT_WORK_TREE is set in the environment: pass --repo DIR")
        a.repo = "."
    return a


def main(argv):
    a = parse(argv)
    if not os.path.isdir(a.repo):
        print("error: --repo %s is not a directory" % a.repo, file=sys.stderr)
        return 2
    t = Train(a)
    atexit.register(t.cleanup)
    for sig in SIGS:
        signal.signal(sig, t.on_signal)
    try:
        return t.run()
    except Fatal as e:
        sys.stdout.flush()
        print("error: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001 -- the contract: never a traceback, always a JSON line
        sys.stdout.flush()
        msg = "unexpected %s: %s" % (type(e).__name__, str(e).split("\n")[0][:200])
        print("error: %s" % msg, file=sys.stderr)
        t.cleanup()
        print(json.dumps({"error": msg, "landed": [], "ejected": t.ejected, "deferred": t.deferred,
                          "runs": t.runs, "batch": 0, "branch": "", "commits": {},
                          "runs_per": t.runs_per}, separators=(",", ":")))
        sys.stdout.flush()
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
