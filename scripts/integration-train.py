#!/usr/bin/env python3
"""integration-train: verify a batch of reviewed changes ONCE on the joined tree.

Run it as:  python3 -I -B scripts/integration-train.py --base REF --verify CMD CAND...
Python 3 standard library only. It NEVER pushes, merges or touches a remote.
"""
import argparse
import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EPILOG = """\
Algorithm (one batch per invocation):
 1. Admission, in the given order, joining into one admission worktree: one whose
    changed paths (union over its commits beyond the base) overlap an admitted
    member is 'deferred: overlaps <other> on <path>'; beyond the window it is
    deferred 'batch full'; one that does not apply (cherry-pick / squash
    conflict) is 'ejected: conflict' with no verify run. The window is
    --max-batch, or 'next' from --state.
 2. Join: inside TEMPORARY worktrees only (cwd = the temp worktree, never the
    caller's tree), one commit per candidate in the given order: a single-commit
    candidate is `git cherry-pick`ed; a multi-commit branch is `git merge
    --squash`ed and committed as ONE commit whose subject is the candidate name
    and whose body lists its original subjects. A conflict is detected by exit
    status and undone (`cherry-pick --abort`; a squash conflict recreates the
    worktree from the last good commit). Porcelain only: needs git >= 2.31
    (checked at start, exit 2 otherwise). Prefix commits are cached, so a set
    starts from its longest already-joined prefix.
 3. Verify the whole batch once. Green: landed.
 4. Red: bisect by halving. Verify the first half on a fresh worktree; green
    means the second half is known to hold the failure, so its OWN whole run is
    skipped and it is split directly (a singleton is then ejected 'inferred');
    red means recurse into the first half and still test the second. A single
    candidate red alone is 'ejected: red', its last 20 output lines in a file.
 5. The survivors are joined and verified again unless that exact set already
    passed. Red there although every member passed in a group: find the
    smallest red prefix by halving, name the minimal failing set, eject the
    LATER member as 'interaction', repeat. A tree never verified green never lands.
 With --state the next window is +1 after a batch landed whole on its first
 run, halved (min 1) after any red.
Exit: 0 all admitted landed, 1 something ejected, 2 usage/git error,
      3 nothing was verified. The last stdout line is one JSON object.
"""


class Fatal(Exception):
    pass


MIN_GIT = (2, 31)


class JoinFail(Exception):
    def __init__(self, cid, squash=False):
        Exception.__init__(self, cid)
        self.squash = squash


class Cand:
    def __init__(self, cid):
        self.id = cid
        self.tip = None
        self.kind = "pick"
        self.paths = set()
        self.message = ""
        self.author = {}
        self.subjects = []


class Train:
    def __init__(self, a):
        self.a = a
        self.repo = os.path.abspath(a.repo)
        self.tmp = tempfile.mkdtemp(prefix="itrain-")
        self.uid = os.path.basename(self.tmp)
        self.worktrees = []
        self.branches = []
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

    # ---- plumbing -------------------------------------------------------
    def git(self, *args, input=None, env=None, ok=(0,), cwd=None):
        e = dict(os.environ)
        if env:
            e.update(env)
        p = subprocess.run(["git"] + list(args), cwd=cwd or self.repo, input=input,
                           capture_output=True, text=True, env=e)
        if p.returncode not in ok:
            first = (p.stderr.strip().split("\n") or [""])[0][:200]
            raise Fatal("git %s failed (exit %d): %s" % (args[0], p.returncode, first))
        return p

    def check_git_version(self):
        try:
            out = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout
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

    def apply(self, wt, c):
        """Join candidate c onto the HEAD of the temp worktree wt; return the new HEAD."""
        env = {"GIT_COMMITTER_NAME": "integration-train", "GIT_COMMITTER_EMAIL": "train@localhost",
               "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "commit.gpgsign",
               "GIT_CONFIG_VALUE_0": "false", "GIT_CONFIG_KEY_1": "core.hooksPath",
               "GIT_CONFIG_VALUE_1": "/dev/null"}
        if c.kind == "pick":
            p = self.git("cherry-pick", c.tip, env=env, ok=(0, 1), cwd=wt)
            if p.returncode == 1:
                self.git("cherry-pick", "--abort", cwd=wt)
                raise JoinFail(c.id)
        else:
            p = self.git("merge", "--squash", c.tip, env=env, ok=(0, 1), cwd=wt)
            if p.returncode == 1:
                raise JoinFail(c.id, squash=True)
            env.update(c.author or {"GIT_AUTHOR_NAME": "integration-train",
                                    "GIT_AUTHOR_EMAIL": "train@localhost"})
            self.git("commit", "-q", "--no-verify", "-F", "-", input=c.message, env=env, cwd=wt)
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
        for b in self.branches:
            if self.a.keep and b == self.final_branch:
                continue
            subprocess.run(["git", "branch", "-D", b], cwd=self.repo, capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def drop_worktree(self, wt):
        subprocess.run(["git", "worktree", "remove", "--force", wt], cwd=self.repo,
                       capture_output=True)
        if wt in self.worktrees:
            self.worktrees.remove(wt)

    # ---- admission ------------------------------------------------------
    def resolve_all(self, refs):
        """One cat-file call resolves the base and every candidate."""
        p = subprocess.run(["git", "cat-file", "--batch-check"], cwd=self.repo, capture_output=True,
                           text=True, input="".join(r + "^{commit}\n" for r in refs))
        lines = p.stdout.split("\n")
        out = []
        for i, r in enumerate(refs):
            parts = lines[i].split() if i < len(lines) else []
            if p.returncode != 0 or len(parts) != 3 or parts[1] != "commit":
                raise Fatal("does not resolve: %s" % r)
            out.append(parts[0])
        return out

    def admit(self, base_sha, window):
        batch = []
        owner = {}
        wt = None
        last = base_sha
        for cid in self.a.candidates:
            c = self.cands[cid]
            raw = self.git("log", "--reverse", "--name-only",
                           "--format=%x02%an%x00%ae%x00%aI%x00%s%x00%P%x00%B%x01",
                           c.tip, "^" + base_sha).stdout
            recs = [r for r in raw.split("\x02") if r.strip("\n")]
            if not recs:
                self.eject(cid, "empty", ["no commits beyond the base"])
                continue
            fields = []
            paths = set()
            for r in recs:
                head, names = r.split("\x01", 1)
                fields.append(head.split("\x00", 5))
                paths.update(n for n in names.split("\n") if n)
            c.paths = paths
            c.subjects = [f[3] for f in fields]
            if len(fields) == 1 and len(fields[0][4].split()) == 1:
                c.kind = "pick"
                c.author = {}
            else:
                c.kind = "squash"
                c.message = "%s\n\n%s\n" % (cid, "\n".join("- " + x for x in c.subjects))
                c.author = {}
            hit = None
            for path in sorted(c.paths):
                if path in owner:
                    hit = (owner[path], path)
                    break
            overlap = hit
            if overlap:
                self.deferred.append({"id": cid, "why": "overlaps %s on %s" % overlap})
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
                fh.write("\n".join(tail[-20:]) + "\n")
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

    def exec_once(self, wt, ids):
        self.n_exec += 1
        self.runs += 1
        for i in ids:
            self.runs_per[i] = self.runs_per.get(i, 0) + 1
        out = os.path.join(self.tmp, "out%d.log" % self.n_exec)
        t0 = time.time()
        reason = None
        with open(out, "w") as fh:
            p = subprocess.Popen(self.a.verify, shell=True, cwd=wt, stdout=fh,
                                 stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True)
            try:
                try:
                    rc = p.wait(timeout=self.a.verify_timeout or None)
                except subprocess.TimeoutExpired:
                    reason = "timeout"
                    self.kill_group(p)
                    rc = p.wait()
            finally:
                self.kill_group(p)
                p.poll()
        dt = time.time() - t0
        with open(out, errors="replace") as fh:
            text = fh.read()
        ok = rc == 0 and reason is None
        if reason == "timeout":
            text += "\nTIMEOUT after %ss\n" % self.a.verify_timeout
        print("run %d: [%s] %s %.2fs" % (self.runs, ",".join(ids), "green" if ok else
                                         "red (%s)" % (reason or "exit %d" % rc), dt))
        return ok, text, reason

    def verify(self, ids):
        key = tuple(ids)
        if key in self.cache:
            return self.cache[key][0]
        k = len(ids)
        while k > 0 and tuple(ids[:k]) not in self.commits:
            k -= 1
        start = self.commits[tuple(ids[:k])] if k else self.base_sha
        wt = self.new_worktree(start)
        try:
            try:
                for j in range(k, len(ids)):
                    sha = self.apply(wt, self.cands[ids[j]])
                    self.commits[tuple(ids[:j + 1])] = sha
            except JoinFail as e:
                res = (False, ["join conflict applying %s" % e], "conflict")
                self.cache[key] = res
                for i in ids:
                    self.last_red[i] = res[1:]
                return False
            ok, text, reason = self.exec_once(wt, ids)
            if not ok and reason is None and self.a.flaky_rerun:
                matched = next((r for r in self.patterns if re.search(r, text)), None)
                if matched is not None:
                    print("rerun: matched %s" % matched)
                    ok, text, reason = self.exec_once(wt, ids)
        finally:
            self.drop_worktree(wt)
        tail = text.rstrip("\n").split("\n")[-20:]
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

    # ---- driver ---------------------------------------------------------
    def read_state(self):
        if self.a.state and os.path.exists(self.a.state):
            try:
                with open(self.a.state) as fh:
                    n = int(json.load(fh)["next"])
                if n >= 1:
                    return n
            except (ValueError, KeyError, TypeError, OSError):
                pass
        return self.a.max_batch

    def write_state(self, window, admitted, bad, first_green):
        if not self.a.state:
            return
        nxt = window + 1 if first_green else max(1, window // 2)
        doc = {"next": nxt, "window": window, "last_p": bad / float(admitted),
               "last_runs": self.runs, "admitted": admitted}
        tmpf = self.a.state + ".tmp%d" % os.getpid()
        with open(tmpf, "w") as fh:
            json.dump(doc, fh, separators=(",", ":"))
        os.replace(tmpf, self.a.state)

    def run(self):
        if self.a.flaky_rerun:
            try:
                with open(self.a.flaky_rerun) as fh:
                    self.patterns = [ln.strip() for ln in fh
                                     if ln.strip() and not ln.lstrip().startswith("#")]
            except OSError as e:
                raise Fatal("cannot read --flaky-rerun file: %s" % e)
        self.check_git_version()
        self.git("rev-parse", "--git-dir")
        refs = [self.a.base] + list(self.a.candidates)
        shas = self.resolve_all(refs)
        self.base_sha = shas[0]
        for cid, sha in zip(self.a.candidates, shas[1:]):
            if cid not in self.cands:
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
            if landed:
                for k in range(1, len(landed) + 1):
                    commits[landed[k - 1]] = self.commits[tuple(landed[:k])]
                branch = "train-" + self.uid
                self.branches.append(branch)
                self.git("branch", branch, self.commits[tuple(landed)])
                self.final_branch = branch
            bad = len([e for e in self.ejected if e["why"] not in ("conflict", "empty")])
            first_green = self.runs == 1 and not self.ejected and landed == batch
            self.write_state(window, len(batch), bad, first_green)
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


def parse(argv):
    ap = argparse.ArgumentParser(
        prog="integration-train.py",
        description="Verify an ordered batch of candidate branches ONCE on their joined tree; "
                    "bisect by halving on red. Never pushes, merges or touches a remote.",
        epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, help="base ref the batch is joined onto")
    ap.add_argument("--verify", required=True, metavar="CMD",
                    help="shell command run in the joined worktree; exit 0 = green")
    ap.add_argument("--max-batch", type=int, default=4, help="window size when no --state (default 4)")
    ap.add_argument("--state", metavar="FILE", help="adaptive-window state file (JSON)")
    ap.add_argument("--flaky-rerun", metavar="FILE",
                    help="file of regexes of KNOWN flaky tests; a red whose output matches one "
                         "is re-run once")
    ap.add_argument("--verify-timeout", type=float, default=0, metavar="SECONDS",
                    help="kill the verify process group after SECONDS; counts as red 'timeout'")
    ap.add_argument("--keep", action="store_true", help="keep the landed integration branch")
    ap.add_argument("--repo", default=".", help="repository or worktree (default: cwd)")
    ap.add_argument("--log-dir", default=os.path.join(tempfile.gettempdir(), "integration-train-logs"),
                    help="where ejected candidates' last 20 output lines are saved")
    ap.add_argument("candidates", nargs="+", metavar="CAND", help="ordered branches or commits")
    a = ap.parse_args(argv)
    if a.max_batch < 1:
        ap.error("--max-batch must be >= 1")
    return a


def main(argv):
    a = parse(argv)
    t = Train(a)
    atexit.register(t.cleanup)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, t.on_signal)
    try:
        return t.run()
    except Fatal as e:
        sys.stdout.flush()
        print("error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
