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
  gitdigest WORKDIR          sha256 over the git metadata an executing git key can live in: everything under
                             WORKDIR/.git except objects/ index logs/ refs/ packed-refs, plus every .gitattributes
                             and .gitmodules in the tree (paths, modes, link targets, bytes). `.git` that is not a
                             plain directory digests as its own marker.
  stale ROOT PREFIX MINUTES  print (NUL separated) each entry of ROOT named PREFIX*, owned by this uid, a real
                             directory (never a symlink), not marked .eval-keep, last modified > MINUTES ago.
"""
import hashlib
import os
import select
import signal
import stat
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


GIT_SKIP = {"objects", "index", "logs", "refs", "packed-refs"}


def gitdigest(work):
    h = hashlib.sha256()

    def add(rel, p):
        try:
            st = os.lstat(p)
        except OSError:
            h.update(("missing %s\n" % rel).encode())
            return
        h.update(("%s %o\n" % (rel, st.st_mode)).encode("utf-8", "surrogateescape"))
        if stat.S_ISLNK(st.st_mode):
            h.update(os.readlink(p).encode("utf-8", "surrogateescape"))
        elif stat.S_ISREG(st.st_mode):
            with open(p, "rb") as f:
                h.update(f.read())
        h.update(b"\n")

    g = os.path.join(work, ".git")
    try:
        gst = os.lstat(g)
    except OSError:
        gst = None
    if gst is None or not stat.S_ISDIR(gst.st_mode):
        h.update(b".git is absent or not a directory\n")
        if gst is not None:
            add(".git", g)
    else:
        for d, dirs, files in os.walk(g, followlinks=False):
            rel = os.path.relpath(d, g)
            if rel == ".":
                dirs[:] = sorted(x for x in dirs if x not in GIT_SKIP)
                files = [x for x in files if x not in GIT_SKIP]
            else:
                dirs[:] = sorted(dirs)
            add(".git/" + rel, d)
            for x in sorted(files):
                add(".git/" + os.path.join(rel, x), os.path.join(d, x))
            for x in sorted(dirs):   # a symlink to a directory is listed in dirs by os.walk: record the link
                p = os.path.join(d, x)
                if os.path.islink(p):
                    add(".git/" + os.path.join(rel, x), p)
    for d, dirs, files in os.walk(work, followlinks=False):
        dirs[:] = sorted(x for x in dirs if x != ".git")
        for x in sorted(files):
            if x in (".gitattributes", ".gitmodules"):
                add(os.path.relpath(os.path.join(d, x), work), os.path.join(d, x))
    print(h.hexdigest())
    return 0


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
        if a[0] == "stale" and len(a) == 4:
            return stale(a[1], a[2], a[3])
    except IndexError:
        pass
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
