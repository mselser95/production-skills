#!/usr/bin/env python3
"""scrub.py <command> ...   the harness's cell-hygiene helpers (never reads or prints a credential).

  reset DIR                  make every directory under DIR (and DIR) owner-rwx and clear the user/system
                             immutable flags on every entry, WITHOUT following a symlink (lchmod / lchflags on
                             the entry itself). The agent may write the cell home, so it can `chmod 000` a
                             directory or `chflags uchg` a file: without this, `rm -rf` of the cell fails and the
                             staged credential copy is left behind. Always exit 0 (best effort; the caller verifies).
  hold SRC DST CTL PIDFILE   stage the credential: SRC is opened O_NOFOLLOW (a symlink / non-regular file / > 1 MiB
                             is refused, exit 3), DST is created NEW (O_EXCL, O_NOFOLLOW) at mode 0600, and the
                             descriptor of THAT inode stays open in a small background process (pid in PIDFILE).
                             The process wipes the inode THROUGH THE DESCRIPTOR (overwrite with zeros, ftruncate 0,
                             fsync) when the FIFO CTL reaches EOF (the adapter closes its end, or died) or on
                             SIGTERM/SIGHUP/SIGINT, then exits. A wipe through the descriptor destroys the content
                             for every hard link to the inode, whatever the names or directory permissions are.
                             Exit 0 only after DST is staged and the holder is running.
  waitgone PIDFILE SECS      wait (ONE bounded wait, 50 ms steps) until the pid in PIDFILE is gone; exit 0 gone,
                             1 still alive after SECS.
  gitdigest WORKDIR          sha256 over the git metadata an executing git key can live in, at ANY depth of WORKDIR: every
                             directory AND every file (gitfile) named .git, symlinks included as "link -> target text";
                             inside each git dir: index, HEAD, config*, hooks/, info/, refs/, packed-refs, commondir,
                             objects/info/alternates, modules/ (each module a git dir again); plus every .gitattributes
                             and .gitmodules. Records (path, type, mode, size, content hash), sorted. Walked by directory
                             descriptor, no symlink followed. NOT covered: ordinary content (tracked or untracked files,
                             .gitignore), objects/ (bar alternates), logs/, and git dir files outside the list above.
                             Exit 1 and no digest when WORKDIR cannot be opened (the caller fails closed).
  rmcell ROOT [--keep NAME]...
                             remove everything under ROOT (and ROOT itself unless --keep is given) through directory
                             descriptors only: ROOT is lstat'ed (a real directory owned by this uid, else exit 2 and
                             nothing is touched) and opened O_NOFOLLOW; every child is stat'ed with dir_fd and
                             follow_symlinks=False and opened O_NOFOLLOW|O_DIRECTORY, so a name the agent replaced by a
                             symlink is UNLINKED AS A NAME and its target is never touched. A top-level child that is
                             neither a directory nor a regular file prints `tampered <name>` on stdout (nested links,
                             FIFOs, sockets are ordinary content and just removed). Permissions (0700) and the user
                             immutable flags are reset on the way down. A child on another device is never crossed:
                             `foreign-device <name>`. Names given to --keep are left alone at the top level only.
                             Exit 0 only when nothing but the kept names remains; else 1 with one stderr line
                             `survivor: <name>` naming the first that remains.
  rmname ROOT REL            remove the ONE name REL (a relative path, no `.`/`..`) under ROOT by the same descriptor walk:
                             each component is opened O_NOFOLLOW|O_DIRECTORY; a component that is not a real directory
                             is unlinked as a name (nothing outside is touched) and `tampered <path so far>` is printed.
                             The last name (a staged credential) is unlinked; if it is a symlink / special file it is
                             also `tampered`. Exit 0 when the name is gone, 1 `survivor: <rel>`, 2 on a bad ROOT.
  sweepok DIR                exit 0 when DIR may be swept for stale cells; 1 (reason on stderr) when it is empty, `/`, /tmp,
                             /private/tmp, /var/tmp, /private/var/tmp (by name or real path), or not a directory owned by
                             this uid: a shared temp root is never swept.
  stale ROOT PREFIX MINUTES  print (NUL separated) each entry of ROOT named PREFIX*, owned by this uid, a real
                             directory (never a symlink), not marked .eval-keep, last modified > MINUTES ago.
"""
import hashlib
import os
import resource
import select
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True


def reset(root):
    try:
        st = os.lstat(root)
    except OSError:
        return 0
    stack = [root] if stat.S_ISDIR(st.st_mode) else []
    _noflags(root)
    while stack:
        d = stack.pop()
        try:
            os.chmod(d, 0o700, follow_symlinks=False)
        except (OSError, NotImplementedError):
            pass
        _noflags(d)
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                _noflags(e.path)
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                except OSError:
                    pass
    return 0


def _noflags(p):
    fn = getattr(os, "chflags", None)
    if fn is None:
        return
    try:
        fn(p, 0, follow_symlinks=False)
    except (OSError, NotImplementedError):
        pass


def hold(src, dst, ctl, pidfile):
    try:
        fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        print("auth.json is a symlink or cannot be opened (%s): refused" % e.strerror, file=sys.stderr)
        return 3
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_size > (1 << 20):
        print("auth.json is not a small regular file: refused", file=sys.stderr)
        return 3
    data = b""
    while True:
        c = os.read(fd, 65536)
        if not c:
            break
        data += c
    os.close(fd)
    try:
        os.mkfifo(ctl, 0o600)
        o = os.open(dst, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        print("cannot stage the credential copy: %s" % e.strerror, file=sys.stderr)
        return 3
    os.fchmod(o, 0o600)
    os.write(o, data)
    size = len(data)
    data = b""
    r, w = os.pipe()
    pid = os.fork()
    if pid:
        os.close(w)
        os.close(o)   # the holder child keeps its own copy of the descriptor
        ok = os.read(r, 1)
        os.close(r)
        return 0 if ok == b"1" else 3
    # ---- holder child: stays in the caller's process group (a group kill reaches it and wipes) ----
    os.close(r)
    dn = os.open(os.devnull, os.O_RDWR)
    for t in (0, 1, 2):   # never hold the caller's pipes open (a command substitution around `hold` would hang)
        os.dup2(dn, t)
    os.close(dn)
    try:
        with open(pidfile + ".tmp", "w") as f:
            f.write("%d\n" % os.getpid())
        os.replace(pidfile + ".tmp", pidfile)
    except OSError:
        os._exit(3)
    done = [False]

    def wipe(*_a):
        if done[0]:
            return
        done[0] = True
        try:
            os.lseek(o, 0, os.SEEK_SET)
            os.write(o, b"\0" * size)
            os.ftruncate(o, 0)
            os.fsync(o)
        except OSError:
            pass

    def on_sig(_s, _f):
        wipe()
        os._exit(0)

    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, on_sig)
    # opening the FIFO for reading blocks until the adapter opens its write end (right after `hold` returns)
    os.write(w, b"1")
    os.close(w)
    try:
        cfd = os.open(ctl, os.O_RDONLY)
        while True:
            c = os.read(cfd, 4096)
            if not c:
                break
    except OSError:
        pass
    wipe()
    os._exit(0)


def waitgone(pidfile, secs):
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return 0
    end = time.time() + float(secs)
    while time.time() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return 0
        except PermissionError:
            return 0
        select.select([], [], [], 0.05)
    return 1


DIGEST_MAXDEPTH = 200
# the entries of a git dir that are digested (config* is matched by prefix); everything else in it is not git metadata an executing key can live in
GITDIR_KEEP = ("index", "HEAD", "hooks", "info", "refs", "packed-refs", "commondir", "modules", "objects")


def _hash_fd(fd):
    h = hashlib.sha256()
    while True:
        b = os.read(fd, 1 << 20)
        if not b:
            return h.hexdigest()
        h.update(b)


class _Digest:
    """Read-only sibling of _Walk: directory descriptors, O_NOFOLLOW, no symlink ever followed, one device."""

    def __init__(self, dev):
        self.dev, self.recs = dev, []

    def rec(self, rel, kind, mode, size, content):
        self.recs.append("\0".join((rel, kind, "%o" % mode, str(size), content)))

    def entry(self, dfd, name, rel):
        """Record one name; returns its lstat when it is a directory (the caller may descend), else None."""
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        except OSError:
            self.rec(rel, "x", 0, 0, "unreadable")
            return None
        m = stat.S_IMODE(st.st_mode)
        if stat.S_ISDIR(st.st_mode):
            self.rec(rel, "d", m, 0, "")
            return st
        if stat.S_ISLNK(st.st_mode):
            try:
                t = os.readlink(name, dir_fd=dfd)
            except OSError:
                self.rec(rel, "x", m, 0, "unreadable")
                return None
            self.rec(rel, "l", m, len(t), hashlib.sha256(os.fsencode(t)).hexdigest())
        elif stat.S_ISREG(st.st_mode):
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
            except OSError:
                self.rec(rel, "x", m, st.st_size, "unreadable")
                return None
            try:
                fs = os.fstat(fd)
                if not stat.S_ISREG(fs.st_mode) or (fs.st_dev, fs.st_ino) != (st.st_dev, st.st_ino):
                    self.rec(rel, "x", m, 0, "swapped")
                else:
                    self.rec(rel, "f", m, fs.st_size, _hash_fd(fd))
            except OSError:
                self.rec(rel, "x", m, st.st_size, "unreadable")
            finally:
                os.close(fd)
        else:
            self.rec(rel, "o", m, 0, "")
        return None

    def open_dir(self, dfd, name, st, rel, depth):
        if st.st_dev != self.dev:
            self.rec(rel, "x", 0, 0, "foreign-device")
            return None
        if depth >= DIGEST_MAXDEPTH:
            self.rec(rel, "x", 0, 0, "too-deep")
            return None
        try:
            cfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
        except OSError:
            self.rec(rel, "x", 0, 0, "unopenable")
            return None
        try:
            cs = os.fstat(cfd)
            if (cs.st_dev, cs.st_ino) == (st.st_dev, st.st_ino):
                return cfd
        except OSError:
            pass
        os.close(cfd)
        self.rec(rel, "x", 0, 0, "swapped")
        return None

    def names(self, fd, rel):
        try:
            return sorted(os.listdir(fd))
        except OSError:
            self.rec(rel, "x", 0, 0, "unlistable")
            return []

    def tree(self, dfd, rel, depth):
        """Ordinary directory: every .git (dir, gitfile or link) and every .gitattributes/.gitmodules, at any depth."""
        for n in self.names(dfd, rel):
            r = rel + n
            if n == ".git":
                st = self.entry(dfd, n, r)
                cfd = self.open_dir(dfd, n, st, r, depth + 1) if st is not None else None
                if cfd is not None:
                    try:
                        self.gitdir(cfd, r + "/", depth + 1)
                    finally:
                        os.close(cfd)
            elif n in (".gitattributes", ".gitmodules"):
                self.entry(dfd, n, r)
            else:
                try:
                    st = os.stat(n, dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    cfd = self.open_dir(dfd, n, st, r, depth + 1)
                    if cfd is not None:
                        try:
                            self.tree(cfd, r + "/", depth + 1)
                        finally:
                            os.close(cfd)

    def full(self, dfd, rel, depth):
        for n in self.names(dfd, rel):
            st = self.entry(dfd, n, rel + n)
            cfd = self.open_dir(dfd, n, st, rel + n, depth + 1) if st is not None else None
            if cfd is not None:
                try:
                    self.full(cfd, rel + n + "/", depth + 1)
                finally:
                    os.close(cfd)

    def gitdir(self, dfd, rel, depth):
        for n in self.names(dfd, rel):
            if n not in GITDIR_KEEP and not n.startswith("config"):
                continue
            r = rel + n
            st = self.entry(dfd, n, r)
            if st is None:
                continue
            cfd = self.open_dir(dfd, n, st, r, depth + 1)
            if cfd is None:
                continue
            try:
                if n == "modules":   # each module is a git dir again
                    for mn in self.names(cfd, r + "/"):
                        mst = self.entry(cfd, mn, r + "/" + mn)
                        mfd = self.open_dir(cfd, mn, mst, r + "/" + mn, depth + 2) if mst is not None else None
                        if mfd is not None:
                            try:
                                self.gitdir(mfd, r + "/" + mn + "/", depth + 2)
                            finally:
                                os.close(mfd)
                elif n == "objects":   # only the alternates file: the object store itself is content-addressed data
                    ist = self.entry(cfd, "info", r + "/info")
                    ifd = self.open_dir(cfd, "info", ist, r + "/info", depth + 2) if ist is not None else None
                    if ifd is not None:
                        try:
                            if "alternates" in self.names(ifd, r + "/info/"):
                                self.entry(ifd, "alternates", r + "/info/alternates")
                        finally:
                            os.close(ifd)
                else:
                    self.full(cfd, r + "/", depth + 1)
            finally:
                os.close(cfd)


def gitdigest(work):
    o = _open_root(work)
    if o is None:
        print("gitdigest: %s is not a directory of ours" % _q(work), file=sys.stderr)
        return 1
    fd, st = o
    try:
        d = _Digest(st.st_dev)
        d.tree(fd, "", 0)
    finally:
        os.close(fd)
    h = hashlib.sha256()
    for r in sorted(d.recs):
        h.update(r.encode("utf-8", "surrogateescape"))
        h.update(b"\n")
    print(h.hexdigest())
    return 0


# ---- descriptor-based removal ---------------------------------------------------------------------------------------------
# THREAT: the agent writes the cell's children (home gocache celltmp work) and may replace any of them by a symlink to a
# directory it wants harmed (`rm -rf $HOME; ln -s <victim> $HOME`); a path-based `rm`/`chmod` by the harness would then act on
# the victim. NOTHING here follows a path through an agent-reachable name: ROOT is opened once (O_NOFOLLOW, after an lstat
# that proves a real directory of ours) and every step is relative to a verified directory descriptor.
# WHY ROOT ITSELF IS SAFE: lib/seatbelt.py allows the agent to write only the SUBPATHS home, gocache, celltmp (and work in
# workspace-write mode) and denies every other write, so the cell root `$TMPDIR/eval-cell.X` and the adapter's sbx.* dirs
# cannot be renamed or replaced by the agent. With the sandbox OFF (explicit opt-out, row sandbox:off) the agent runs as the
# user and could do anything anyway; that configuration is outside this guarantee.
# FLAGS: Python has no fchflags. A flag is cleared with `os.chflags(name, 0, follow_symlinks=False)` on a SINGLE-COMPONENT
# relative name after `os.fchdir(dfd)` into the verified directory: lchflags never follows a symlink, so the worst a swap
# between the stat and that call can do is clear the flags of another entry of the same cell directory (residual race,
# harmless). Platforms without chflags (Linux) skip it.
MAXDEPTH = 3000
_UCHG = getattr(stat, "UF_IMMUTABLE", 0) | getattr(stat, "UF_APPEND", 0)


def _q(name):
    return name.encode("unicode_escape", "backslashreplace").decode("ascii") if isinstance(name, str) else repr(name)


def _raise_nofile():
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        want = 8192 if hard == resource.RLIM_INFINITY else min(hard, 8192)
        if soft == resource.RLIM_INFINITY or soft < want:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
    except (OSError, ValueError):
        pass


def _noflags_at(dfd, name, st):
    if not getattr(st, "st_flags", 0) or not hasattr(os, "chflags"):
        return
    try:
        os.fchdir(dfd)
        os.chflags(name, 0, follow_symlinks=False)
    except (OSError, NotImplementedError):
        pass


def _open_child_dir(dfd, name, st):
    """Open directory `name` of dfd (its lstat is `st`, a directory) O_NOFOLLOW; None if it cannot be proven the same inode."""
    _noflags_at(dfd, name, st)
    try:
        os.chmod(name, 0o700, dir_fd=dfd, follow_symlinks=False)
    except (OSError, NotImplementedError):
        pass
    try:
        cfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
    except OSError:
        return None
    try:
        cs = os.fstat(cfd)
        if (cs.st_dev, cs.st_ino) != (st.st_dev, st.st_ino) or not stat.S_ISDIR(cs.st_mode):
            os.close(cfd)
            return None
        os.fchmod(cfd, 0o700)
    except OSError:
        pass
    return cfd


def _unlink(dfd, name):
    try:
        os.unlink(name, dir_fd=dfd)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        pass
    try:
        st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        _noflags_at(dfd, name, st)
        os.unlink(name, dir_fd=dfd)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        return False


class _Walk:
    def __init__(self, dev, keep):
        self.dev, self.keep = dev, keep
        self.tampered, self.surv = [], []

    def entry(self, dfd, name, rel, depth, top):
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            return
        except OSError:
            self.surv.append(rel)
            return
        if stat.S_ISDIR(st.st_mode):
            if st.st_dev != self.dev:
                self.surv.append("foreign-device " + _q(rel))
                return
            if depth >= MAXDEPTH:
                self.surv.append("too-deep " + _q(rel))
                return
            cfd = _open_child_dir(dfd, name, st)
            if cfd is None:
                self.surv.append(rel)
                return
            try:
                self.purge(cfd, rel + "/", depth + 1, False)
            finally:
                os.close(cfd)
            try:
                os.rmdir(name, dir_fd=dfd)
            except FileNotFoundError:
                pass
            except OSError:
                _noflags_at(dfd, name, st)
                try:
                    os.rmdir(name, dir_fd=dfd)
                except FileNotFoundError:
                    pass
                except OSError:
                    self.surv.append(rel)
            return
        if top and not stat.S_ISREG(st.st_mode):
            self.tampered.append(rel)
        if not _unlink(dfd, name):
            self.surv.append(rel)

    def purge(self, dfd, prefix, depth, top):
        try:
            names = os.listdir(dfd)
        except OSError:
            self.surv.append(prefix.rstrip("/") or ".")
            return
        for n in sorted(names):
            if top and n in self.keep:
                continue
            self.entry(dfd, n, prefix + n, depth, top)


def _open_root(root):
    """(fd, st) of ROOT opened O_NOFOLLOW after an lstat proving a real directory owned by this uid; None otherwise."""
    try:
        st = os.lstat(root)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            return None
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        return None
    fs = os.fstat(fd)
    if (fs.st_dev, fs.st_ino) != (st.st_dev, st.st_ino):
        os.close(fd)
        return None
    return fd, fs


def rmcell(root, keep):
    _raise_nofile()
    sys.setrecursionlimit(MAXDEPTH * 3 + 1000)
    try:
        os.lstat(root)
    except FileNotFoundError:
        return 0
    except OSError:
        pass
    r = _open_root(root)
    if r is None:
        print("rmcell: %s is not a real directory owned by this user: nothing touched" % _q(root), file=sys.stderr)
        return 2
    fd, fs = r
    keep = set(keep)
    w = _Walk(fs.st_dev, keep)
    try:
        for _try in (1, 2):
            w.surv = []
            w.purge(fd, "", 0, True)
            if not w.surv:
                break
        for t in dict.fromkeys(w.tampered):
            print("tampered " + _q(t))
        sys.stdout.flush()
        if w.surv:
            print("survivor: " + w.surv[0], file=sys.stderr)
            return 1
        if not keep:
            parent = os.path.dirname(os.path.abspath(root)) or "/"
            try:
                pfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            except OSError:
                print("survivor: " + _q(root), file=sys.stderr)
                return 1
            try:
                base = os.path.basename(os.path.abspath(root))
                ps = os.stat(base, dir_fd=pfd, follow_symlinks=False)
                if (ps.st_dev, ps.st_ino) != (fs.st_dev, fs.st_ino):
                    print("survivor: " + _q(root), file=sys.stderr)
                    return 1
                try:
                    os.rmdir(base, dir_fd=pfd)
                except OSError:
                    print("survivor: " + _q(root), file=sys.stderr)
                    return 1
            finally:
                os.close(pfd)
        return 0
    finally:
        os.close(fd)


def rmname(root, rel):
    _raise_nofile()
    comps = rel.split("/")
    if not rel or rel.startswith("/") or any(c in ("", ".", "..") for c in comps):
        print("rmname: REL must be a plain relative path", file=sys.stderr)
        return 2
    r = _open_root(root)
    if r is None:
        print("rmname: %s is not a real directory owned by this user: nothing touched" % _q(root), file=sys.stderr)
        return 2
    fd, fs = r
    opened = [fd]
    w = _Walk(fs.st_dev, set())
    try:
        cur = fd
        for i, c in enumerate(comps[:-1]):
            sofar = "/".join(comps[:i + 1])
            try:
                st = os.stat(c, dir_fd=cur, follow_symlinks=False)
            except FileNotFoundError:
                return 0
            except OSError:
                print("survivor: " + _q(rel), file=sys.stderr)
                return 1
            if stat.S_ISDIR(st.st_mode) and st.st_dev == fs.st_dev:
                nfd = _open_child_dir(cur, c, st)
                if nfd is None:
                    print("survivor: " + _q(sofar), file=sys.stderr)
                    return 1
                opened.append(nfd)
                cur = nfd
                continue
            # not a real directory: the NAME goes, whatever it points at is not touched
            print("tampered " + _q(sofar))
            sys.stdout.flush()
            if not _unlink(cur, c):
                print("survivor: " + _q(sofar), file=sys.stderr)
                return 1
            return 0
        last = comps[-1]
        try:
            st = os.stat(last, dir_fd=cur, follow_symlinks=False)
        except FileNotFoundError:
            return 0
        except OSError:
            print("survivor: " + _q(rel), file=sys.stderr)
            return 1
        if not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
            print("tampered " + _q(rel))
            sys.stdout.flush()
        w.entry(cur, last, _q(rel), 1, False)
        if w.surv:
            print("survivor: " + w.surv[0], file=sys.stderr)
            return 1
        return 0
    finally:
        for o in opened:
            os.close(o)


SHARED_ROOTS = ("/", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp")


def sweepok(d):
    if not d:
        print("TMPDIR is unset or empty", file=sys.stderr)
        return 1
    norm = os.path.normpath(d)
    if norm in SHARED_ROOTS or os.path.realpath(d) in SHARED_ROOTS:
        print("%s is a shared temp root" % _q(d), file=sys.stderr)
        return 1
    try:
        st = os.stat(d)
    except OSError:
        print("%s does not exist" % _q(d), file=sys.stderr)
        return 1
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        print("%s is not a directory owned by this user" % _q(d), file=sys.stderr)
        return 1
    return 0


def _ps_start(pid):
    """The raw start time of `pid` (`ps -o lstart=`, C locale), or None when ps cannot say."""
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10,
                           env={"LC_ALL": "C", "PATH": "/bin:/usr/bin"})
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() or None


def live(cell):
    """True only when <cell>/.eval-live is a small regular file of ours naming pid + start time of a process that is alive NOW with
    that very start time. Anything unreadable, malformed or not matching is "not provably live" (False): the age rule applies."""
    try:
        fd = os.open(os.path.join(cell, ".eval-live"), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 256:
            return False
        data = os.read(fd, 300).decode("utf-8", "replace")
    except OSError:
        return False
    finally:
        os.close(fd)
    lines = data.split("\n")
    if len(lines) < 2 or not lines[0].isdigit() or not lines[1].strip():
        return False
    pid = int(lines[0])
    if pid < 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except OSError:
        return False
    return _ps_start(pid) == lines[1].strip()


def stale(root, prefix, minutes):
    now = time.time()
    me = os.getuid()
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return 0
    for n in names:
        if not n.startswith(prefix):
            continue
        p = os.path.join(root, n)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != me:
            continue
        if now - st.st_mtime < float(minutes) * 60:
            continue
        try:
            os.lstat(os.path.join(p, ".eval-keep"))
            continue
        except OSError:
            pass
        if live(p):
            continue
        sys.stdout.write(p + "\0")
    return 0


def main():
    a = sys.argv[1:]
    try:
        if a[0] == "reset" and len(a) == 2:
            return reset(a[1])
        if a[0] == "hold" and len(a) == 5:
            return hold(*a[1:])
        if a[0] == "waitgone" and len(a) == 3:
            return waitgone(a[1], a[2])
        if a[0] == "gitdigest" and len(a) == 2:
            return gitdigest(a[1])
        if a[0] == "rmcell" and len(a) >= 2:
            keep, i = [], 2
            while i < len(a):
                if a[i] == "--keep" and i + 1 < len(a):
                    keep.append(a[i + 1])
                    i += 2
                else:
                    raise IndexError
            return rmcell(a[1], keep)
        if a[0] == "rmname" and len(a) == 3:
            return rmname(a[1], a[2])
        if a[0] == "sweepok" and len(a) == 2:
            return sweepok(a[1])
        if a[0] == "stale" and len(a) == 4:
            return stale(a[1], a[2], a[3])
    except IndexError:
        pass
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
