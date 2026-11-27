#!/usr/bin/env python3
"""seatbelt.py <workdir> <home> <gocache> <tmpdir> <read-only|workspace-write>
              [--deny-root P]... [--allow-read P]... [--deny-read P]... [--reallow-read P]... [--protect P]...   -> sandbox-exec profile on stdout

WHY. Claude Code has no OS sandbox of its own here (Codex does). A tool
allowlist is a prefix match: `go test -exec <prog>`, `go build -o /anywhere`,
`git diff --output=/path` run or write outside the workdir. This profile is the
actual control. The agent has unrestricted Bash and an open network, so anything
it can READ it can send out: a list of secret paths to deny is never complete
(other clones of the repo, the git object store with the hidden grader, shell
history, other tools' config dirs, the profile file itself ...). So user data is
DEFAULT-DENY and the cell re-allows only what it needs.

Profile, in this order (Seatbelt uses the LAST matching rule):
  1. (allow default); every file WRITE denied except /dev/null /dev/tty /dev/dtracehelper.
  2. file-read* AND file-write* denied on the DENIED ROOTS: /Users /Volumes /tmp /private/tmp
     /var/folders /private/var/folders (`--deny-root P` repeated REPLACES this list: tests use a
     fake tree), and on /var/run + /private/var/run (sockets: docker, agents) always, plus every
     path ending in docker.sock. Unix-socket connect is denied under the denied roots too.
  3. re-allowed, by real path: READ+WRITE on home, GOCACHE, TMPDIR; READ on the workdir (WRITE
     only in workspace-write); READ on each `--allow-read P` that lies under a denied root (the
     CLI's install root, the Go toolchain, git's exec path); unix-socket connect inside the
     three RW dirs.
  4. `--deny-read P` (the repo, the task dir, auth dirs): denied again AFTER the re-allows, and a
     docker.sock / agent socket rule last of all.
  4b. file-read-metadata (stat only), as LITERALS, on each ancestor dir of the re-allowed cell paths that
     lies under a denied root (CLIs canonicalise their home); no data, no listing, no siblings.
  5. `--reallow-read P` (a CLI whose install dir lies INSIDE a `--deny-read` dir, e.g. the real
     ~/.codex/packages/...): READ re-allowed AFTER the denies, for that one dir only; siblings and
     parents stay denied. Refused (exit 2) if P is, or contains, a `--protect` path or a
     `--deny-read` path, or if it is at or above a denied root.
Fail closed (exit 2): a re-allowed path that IS or CONTAINS a denied root, a `--deny-read` path or a
`--protect` path (the profile's own dir): the re-allow would re-open what is denied. Paths are
resolved with realpath (/var -> /private/var) because seatbelt matches the resolved path. No
environment variable is read here. TCP is NOT filtered (the CLI must reach its API).
"""
import os
import sys

sys.dont_write_bytecode = True

DEFAULT_ROOTS = ("/Users", "/Volumes", "/private/tmp", "/tmp", "/private/var/folders", "/var/folders")
RUNTIME_DENY = ("/private/var/run", "/var/run")
SOCK_RE = r'(docker\.sock|agent[^/]*\.sock|S\.gpg-agent[^/]*|S\.ssh-agent[^/]*|/Listeners)$'
USAGE = ("usage: seatbelt.py <workdir> <home> <gocache> <tmpdir> <read-only|workspace-write> "
         "[--deny-root P]... [--allow-read P]... [--deny-read P]... [--reallow-read P]... [--protect P]...")


def bad(p):
    return '"' in p or "\\" in p or "\n" in p


def within(p, root):
    return p == root or p.startswith(root.rstrip("/") + "/")


def forms(p):
    """the path as given (absolute) and its real path: seatbelt matches the real one, humans give the other"""
    a = os.path.abspath(p)
    return sorted({a, os.path.realpath(p)})


def main():
    if len(sys.argv) < 6 or sys.argv[5] not in ("read-only", "workspace-write"):
        print(USAGE, file=sys.stderr)
        return 2
    workdir, home, gocache, tmpdir, mode = sys.argv[1:6]
    rest = sys.argv[6:]
    if len(rest) % 2:
        print("seatbelt.py: option without a value", file=sys.stderr)
        return 2
    roots, allow_read, deny_read, protect, reallow = [], [], [], [], []
    for flag, val in zip(rest[0::2], rest[1::2]):
        if flag == "--deny-root":
            roots.append(val)
        elif flag == "--allow-read":
            allow_read.append(val)
        elif flag == "--deny-read":
            deny_read.append(val)
        elif flag == "--reallow-read":
            reallow.append(val)
        elif flag == "--protect":
            protect.append(val)
        else:
            print("seatbelt.py: unknown option %s" % flag, file=sys.stderr)
            return 2
    roots = roots or list(DEFAULT_ROOTS)
    droots = sorted({f for r in roots for f in forms(r)})
    runtime = sorted({f for r in RUNTIME_DENY for f in forms(r)})
    extras = sorted({f for r in deny_read for f in forms(r)})
    prot = sorted({f for r in protect for f in forms(r)})
    for p in droots + runtime + extras + prot + [workdir, home, gocache, tmpdir] + allow_read + reallow:
        if bad(p) or bad(os.path.realpath(p)):
            print("seatbelt.py: refusing a path with a quote/backslash/newline: %r" % p, file=sys.stderr)
            return 2

    rw = [home, gocache, tmpdir] + ([workdir] if mode == "workspace-write" else [])
    for p in [home, gocache, tmpdir, workdir]:
        os.makedirs(p, exist_ok=True)
    ro = [workdir]
    for p in allow_read:   # emitted only when something denies it; otherwise the re-allow is noise
        r = os.path.realpath(p)
        if any(within(r, d) for d in droots):
            ro.append(p)
    # fail closed: nothing re-allowed may be, or contain, something that stays denied
    guarded = [("denied root", d) for d in droots + runtime] + [("denied path", d) for d in extras] + [("protected path", d) for d in prot]
    for p in set(rw + ro + [workdir, home, gocache, tmpdir]):
        r = os.path.realpath(p)
        for what, d in guarded:
            if within(d, r) or (within(r, d) and what != "denied root"):
                print("seatbelt.py: %s lies %s %s %s; refusing to re-allow it" % (
                    r, "at or above" if within(d, r) else "under", what, d), file=sys.stderr)
                return 2

    # a --reallow-read dir may sit UNDER a denied path (that is its purpose) but must not equal or contain
    # anything that stays denied, nor be at or above a denied root
    for p in reallow:
        r = os.path.realpath(p)
        for what, d in [("denied root", d) for d in droots + runtime] + [("denied path", d) for d in extras] + [("protected path", d) for d in prot]:
            if within(d, r) or (within(r, d) and what == "protected path"):
                print("seatbelt.py: %s lies %s %s %s; refusing to re-allow it" % (
                    r, "at or above" if within(d, r) else "under", what, d), file=sys.stderr)
                return 2

    def subs(paths):
        return " ".join('(subpath "%s")' % os.path.realpath(p) for p in dict.fromkeys(paths))

    out = ["(version 1)", "(allow default)", "(deny file-write*)",
           '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))']
    out.append("(deny file-read* file-write* %s)" % " ".join('(subpath "%s")' % d for d in droots + runtime))
    # a `remote unix-socket` form takes ONE filter (several are not OR-ed, found by trial): one rule per path
    out += ['(deny network-outbound (remote unix-socket (subpath "%s")))' % d for d in droots]
    out.append("(allow file-read* file-write* %s)" % subs(rw[:3]))
    out += ['(allow network-outbound (remote unix-socket (subpath "%s")))' % os.path.realpath(p) for p in rw[:3]]
    if mode == "workspace-write":
        out.append("(allow file-write* %s)" % subs([workdir]))
    out.append("(allow file-read* %s)" % subs(ro))
    # Some CLIs canonicalise their home (lstat of EVERY ancestor); under a denied root that fails. Allow
    # METADATA ONLY (stat) on the ancestor directories themselves, as literals: no data, no listing, and
    # nothing on their siblings or children. Emitted before the --deny-read rules so those still win.
    anc = []
    for p in [home, gocache, tmpdir, workdir]:
        for f in forms(p):   # the path as given too: a CLI lstat()s the symlinked /tmp or /var itself
            d = os.path.dirname(f)
            while d != os.path.dirname(d):
                if any(within(d, r) for r in droots) and d not in anc:
                    anc.append(d)
                d = os.path.dirname(d)
    if anc:
        out.append("(allow file-read-metadata %s)" % " ".join('(literal "%s")' % d for d in anc))
    for d in extras:
        out.append('(deny file-read* file-write* (subpath "%s"))' % d)
    if reallow:
        out.append("(allow file-read* %s)" % subs(reallow))
        # a re-allowed file under a denied path is reached by CLIs that lstat every ancestor first: METADATA ONLY,
        # literals, on its ancestors (no data, no listing, no siblings). Emitted after the denies so it is effective.
        ranc = []
        for p in reallow:
            for f in forms(p):   # as given too: the CLI lstat()s the symlinked /tmp itself
                d = os.path.dirname(f)
                while d != os.path.dirname(d):
                    if d not in ranc:
                        ranc.append(d)
                    d = os.path.dirname(d)
        out.append("(allow file-read-metadata %s)" % " ".join('(literal "%s")' % d for d in ranc))
    out.append('(deny file-read* file-write* (regex #"%s"))' % SOCK_RE)
    out.append('(deny network-outbound (remote unix-socket (path-regex #"%s")))' % SOCK_RE)
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
