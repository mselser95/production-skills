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

EPILOG = """\
Algorithm (one batch per invocation):
 1. Admission, in the given order, joining into one admission worktree: one whose
    changed paths overlap an admitted member is 'deferred: overlaps <other> on
    <path>'; beyond the window it is deferred 'batch full'; one that does not
    apply (cherry-pick / squash conflict) is 'ejected: conflict'; one with NO net
    change (an empty commit, a branch whose commits cancel out, a change the
    base already has) is 'ejected: empty'; neither runs verify. The window is
    --max-batch, or 'next' from --state. The changed-path set of a candidate is
    the union of (a) `git diff --name-only -z --no-renames BASE...TIP` (BASE..TIP when unrelated) and
    (b) `git log -z --format= --name-only --no-renames -m TIP ^BASE`: NUL
    delimited, never mixed with commit messages, merge commits included, a
    rename contributes both names (over-approximating only defers).
 2. Join: inside TEMPORARY worktrees only, one commit per candidate in the given
    order: a single-commit candidate is `git cherry-pick`ed; a multi-commit
    branch (or a merge commit) is `git merge --squash`ed and committed as ONE
    commit whose subject is the candidate name, whose body lists its original
    subjects and whose AUTHOR is the candidate's last author. The committer is
    always 'integration-train <train@localhost>'. A conflict is detected by exit
    status and undone. Porcelain only: needs git >= 2.31 (checked at start,
    exit 2 otherwise). Prefix commits are cached.
 3. EVERY verify run (first run, flaky rerun, each bisection step, the final
    re-join, each recovery) executes in a BRAND-NEW temporary worktree checked
    out at the exact commit under test; before verify starts the tool asserts
    HEAD is that commit and `git status --porcelain --ignored` is empty (else
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
 With --state the next window is +1 after a batch landed whole on its first run,
 halved (min 1) after any red, unchanged when only conflicts/empties were
 ejected; a state file that is unreadable, not an integer in 1..64, or Infinity /
 NaN is ignored with a one-line warning and the window is --max-batch.
Environment and config isolation: EVERY git call is `git -c K=V... -C DIR ...` with
a sanitised environment (all GIT_* removed except GIT_EXEC_PATH; HOME and
XDG_CONFIG_HOME point to an empty temp dir; GIT_CONFIG_NOSYSTEM=1,
GIT_CONFIG_GLOBAL=/dev/null; fixed committer identity). The -c set is:
core.hooksPath=/dev/null core.fsmonitor=false core.untrackedCache=false
core.autocrlf=false core.attributesFile=/dev/null core.excludesFile=/dev/null
core.sparseCheckout=false core.splitIndex=false core.pager=cat core.editor=true
commit.gpgsign=false tag.gpgsign=false gc.auto=0 maintenance.auto=false
rerere.enabled=false submodule.recurse=false advice.detachedHead=false, plus
filter.NAME.clean/smudge=cat for every filter driver the repo config defines. A repo
config that defines filter.*.process or merge.*.driver is refused (exit 2): the tool
never runs code from the caller's config. Hooks never run. The VERIFY command gets
the caller's environment minus every repo-pointing variable (`git rev-parse
--local-env-vars` plus a hard-coded superset, GIT_CONFIG*, GIT_AUTHOR_*,
GIT_COMMITTER_*), PWD set to the worktree, HOME kept. If GIT_DIR or GIT_WORK_TREE is
set and --repo is not given the tool refuses (exit 2): pass --repo.
Limits: a verify child that calls setsid escapes the process-group kill (timeout
or exit) and may outlive the run; the tool cannot see it. Verify output goes to a
file; only the last 64 KiB / 20 lines are kept in memory; --flaky-rerun regexes
match LINE BY LINE over the file (never across lines; a line longer than 64 KiB
is matched in 64 KiB pieces).
Exit: 0 all admitted landed, 1 something ejected, 2 usage/git/unexpected error,
      3 nothing was verified. The last stdout line is one JSON object; on an
      unexpected exception it carries "error".
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

# The -c set on EVERY git call (see EPILOG).
GIT_C = (
    "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.untrackedCache=false",
    "core.autocrlf=false", "core.attributesFile=/dev/null", "core.excludesFile=/dev/null",
    "core.sparseCheckout=false", "core.splitIndex=false", "core.pager=cat",
    "core.editor=true", "commit.gpgsign=false", "tag.gpgsign=false", "gc.auto=0",
    "maintenance.auto=false", "rerere.enabled=false", "submodule.recurse=false",
    "advice.detachedHead=false",
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
        self.message = ""
        self.author = {}
        self.subjects = []


def nul_names(text):
    return set(n for n in text.split("\0") if n)


class Train:
    def __init__(self, a):
        self.a = a
        self.repo = os.path.abspath(a.repo)
        self.tmp = tempfile.mkdtemp(prefix="itrain-")
        self.uid = os.path.basename(self.tmp)
        self.worktrees = []
        self.branches = []  # (name, commit) -- ONLY refs this run created
        self.final_branch = None
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

    # ---- plumbing -------------------------------------------------------
    def build_env(self):
        base = dict(os.environ)
        home = os.path.join(self.tmp, "home")
        os.makedirs(home, exist_ok=True)
        self.genv = {k: v for k, v in base.items() if not k.startswith("GIT_") or k == "GIT_EXEC_PATH"}
        self.genv.update({
            "HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_EDITOR": "true",
            "GIT_COMMITTER_NAME": IDENT_NAME, "GIT_COMMITTER_EMAIL": IDENT_EMAIL})
        drop = set(LOCAL_ENV_SUPERSET)
        try:
            p = subprocess.run(["git", "rev-parse", "--local-env-vars"], cwd=self.tmp,
                               capture_output=True, text=True, env=self.genv)
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

    def scan_config(self):
        """Neutralise code-running drivers of the caller's repo config, or refuse."""
        p = self.git("config", "--null", "--name-only", "--get-regexp",
                     r"^(filter\..*\.(clean|smudge|process)|merge\..*\.driver)$", ok=(0, 1))
        names = nul_names(p.stdout)
        for n in sorted(names):
            if n.endswith(".process") or (n.startswith("merge.") and n.endswith(".driver")):
                raise Fatal("repo config defines %s: refused (the tool never runs code from the caller's config)" % n)
        for n in sorted(names):
            self.cflags += ["-c", n + "=cat"]

    def git(self, sub, *args, input=None, env=None, ok=(0,), cwd=None):
        e = dict(self.genv)
        if env:
            e.update(env)
        cmd = ["git"] + self.cflags + ["-C", cwd or self.repo, sub] + list(args)
        p = subprocess.run(cmd, cwd=self.tmp, input=input, capture_output=True, text=True,
                           encoding="utf-8", errors="surrogateescape", env=e)
        if p.returncode not in ok:
            first = (p.stderr.strip().split("\n") or [""])[0][:200]
            raise Fatal("git %s failed (exit %d): %s" % (sub, p.returncode, first))
        return p

    def check_git_version(self):
        try:
            out = subprocess.run(["git", "--version"], capture_output=True, text=True,
                                 env=self.genv, cwd=self.tmp).stdout
        except OSError as e:
            raise Fatal("cannot run git: %s" % e)
        m = re.search(r"(\d+)\.(\d+)", out)
        if not m:
            raise Fatal("cannot parse git version from %r" % out.strip()[:60])
        found = (int(m.group(1)), int(m.group(2)))
        if found < MIN_GIT:
            raise Fatal("git %d.%d found, %d.%d or newer required" % (found + MIN_GIT))

    def new_worktree(self, commit):
        self.n_wt += 1
        wt = os.path.join(self.tmp, "wt%d" % self.n_wt)
        self.git("worktree", "add", "--quiet", "--detach", wt, commit)
        self.worktrees.append(wt)
        return wt

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
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        for wt in list(self.worktrees):
            self.drop_worktree(wt)
        for b, sha in self.branches:
            if self.a.keep and b == self.final_branch:
                continue
            # only ever delete a ref this run created, and only while it still points
            # at the commit this run created it with
            self.git_quiet("update-ref", "-d", "refs/heads/" + b, sha)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git_quiet(self, sub, *args):
        try:
            e = dict(self.genv) or dict(os.environ)
            subprocess.run(["git"] + self.cflags + ["-C", self.repo, sub] + list(args),
                           cwd=self.tmp if os.path.isdir(self.tmp) else None,
                           capture_output=True, env=e)
        except OSError:
            pass

    def drop_worktree(self, wt):
        self.git_quiet("worktree", "remove", "--force", wt)
        if wt in self.worktrees:
            self.worktrees.remove(wt)

    # ---- admission ------------------------------------------------------
    def resolve_all(self, refs):
        """One cat-file call resolves the base and every candidate."""
        p = self.git("cat-file", "--batch-check", input="".join(r + "^{commit}\n" for r in refs),
                     ok=(0, 1))
        lines = p.stdout.split("\n")
        out = []
        for i, r in enumerate(refs):
            parts = lines[i].split() if i < len(lines) else []
            if p.returncode != 0 or len(parts) != 3 or parts[1] != "commit":
                raise Fatal("does not resolve: %s" % r)
            out.append(parts[0])
        return out

    def describe(self, c, base_sha):
        """Fill c from git; return False when the candidate has no commit beyond the base."""
        revs = [ln.split() for ln in self.git("rev-list", "--parents", "--reverse", c.tip,
                                              "^" + base_sha).stdout.split("\n") if ln.strip()]
        if not revs:
            return False
        d = self.git("diff", "--name-only", "-z", "--no-renames", base_sha + "..." + c.tip, ok=(0, 128))
        if d.returncode != 0:  # no merge base: compare the two trees directly
            d = self.git("diff", "--name-only", "-z", "--no-renames", base_sha, c.tip)
        net = nul_names(d.stdout)
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
        return True

    def admit(self, base_sha, window):
        batch = []
        owner = {}
        wt = None
        last = base_sha
        for cid in self.a.candidates:
            c = self.cands[cid]
            if not self.describe(c, base_sha):
                self.eject(cid, "empty", ["no commits beyond the base"])
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
                    self.eject(cid, "conflict", ["does not apply on the base"])
                continue
            batch.append(cid)
            self.commits[tuple(batch)] = sha
            last = sha
            for path in c.paths:
                owner[path] = cid
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
        t0 = time.time()
        reason = None
        env = dict(self.venv)
        env["PWD"] = wt
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
        tmpf = self.a.state + ".tmp%d" % os.getpid()
        with open(tmpf, "w") as fh:
            json.dump(doc, fh, separators=(",", ":"))
        os.replace(tmpf, self.a.state)

    def create_branch(self, landed):
        sha = self.commits[tuple(landed)]
        branch = "train-%s-%s" % (self.uid, secrets.token_hex(4))
        self.git("branch", branch, sha)  # never -f: an existing name is exit 2, untouched
        got = self.git("rev-parse", "--verify", "refs/heads/" + branch).stdout.strip()
        if got != sha:
            raise Fatal("branch %s does not point at %s" % (branch, sha[:12]))
        self.branches.append((branch, sha))  # recorded only after WE created it
        self.final_branch = branch
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
        self.build_env()
        self.check_git_version()
        if not os.path.isdir(self.repo):
            raise Fatal("--repo %s is not a directory" % self.a.repo)
        try:
            self.git("rev-parse", "--git-dir")
        except Fatal:
            raise Fatal("--repo %s is not a git repository" % self.a.repo)
        self.scan_config()
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
        window = self.read_state()
        batch = self.admit(self.base_sha, window)
        landed = []
        branch = ""
        commits = {}
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
                branch = self.create_branch(landed)
            reds = [e for e in self.ejected if e["why"] not in ("conflict", "empty")]
            quiet = [e for e in self.ejected if e["why"] in ("conflict", "empty")]
            first_green = self.runs == 1 and not reds and landed == batch
            self.write_state(window, len(batch), len(reds), first_green, not quiet)
        for d in self.deferred:
            print("deferred: %s: %s" % (d["id"], d["why"]))
        for cid in landed:
            print("landed: %s %s" % (cid, commits[cid]))
        if branch:
            print("integration branch: %s%s" % (branch, "" if self.a.keep else
                                                " (removed at exit; use --keep)"))
        print("runs: %d (per candidate: %s)" % (
            self.runs, " ".join("%s=%d" % (k, v) for k, v in self.runs_per.items())))
        print("batch: %d" % len(batch))
        summary = {"landed": landed, "ejected": self.ejected, "deferred": self.deferred,
                   "runs": self.runs, "batch": len(batch), "branch": branch,
                   "commits": commits, "runs_per": self.runs_per}
        print(json.dumps(summary, separators=(",", ":")))
        sys.stdout.flush()
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
    ap.add_argument("--keep", action="store_true", help="keep the landed integration branch")
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
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, t.on_signal)
    try:
        return t.run()
    except Fatal as e:
        sys.stdout.flush()
        print("error: %s" % e, file=sys.stderr)
        a.keep = False
        return 2
    except Exception as e:  # noqa: BLE001 -- the contract: never a traceback, always a JSON line
        sys.stdout.flush()
        msg = "unexpected %s: %s" % (type(e).__name__, str(e).split("\n")[0][:200])
        print("error: %s" % msg, file=sys.stderr)
        a.keep = False
        t.cleanup()
        print(json.dumps({"error": msg, "landed": [], "ejected": t.ejected, "deferred": t.deferred,
                          "runs": t.runs, "batch": 0, "branch": "", "commits": {},
                          "runs_per": t.runs_per}, separators=(",", ":")))
        sys.stdout.flush()
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
