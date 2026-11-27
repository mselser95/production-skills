#!/usr/bin/env python3
"""seatbelt.py <workdir> <home> <gocache> <tmpdir> <read-only|workspace-write>
              [--real-home H] [--repo R] [--task-dir T] [--deny-read P]...   -> sandbox-exec profile on stdout

WHY. Claude Code has no OS sandbox of its own here (Codex does). A tool
allowlist is a prefix match: `go test -exec <prog>`, `go build -o /anywhere`,
`git diff --output=/path` run or write outside the workdir. This profile is the
actual control: reads and exec stay open (the agent must read Go's toolchain,
git, ...), every file WRITE is denied except the paths below.

Writable: the isolated host home, the per-cell GOCACHE, the per-cell TMPDIR,
the workdir ONLY in workspace-write mode (in read-only mode the workdir is not
writable), and /dev/null /dev/tty /dev/dtracehelper. Network is NOT filtered
(seatbelt cannot filter by host): the agent holds its own API credential.

READS. The agent has unrestricted Bash and an open network, so anything it can
read it can send out: the read-deny list below is the control for secrets and
for the answer key. Reads stay open otherwise (toolchain, git, system libs, the
claude install). With --real-home: ssh, aws, gnupg, gh, gcloud, netrc, npmrc,
docker, kube, the real ~/.claude* and ~/.codex, ~/Library/Keychains. With --repo:
<repo>/benchmarks/eval/corpus. With --task-dir: the task dir (grader, reference).
A writable/cell path under a denied path is refused (exit 2): fail closed.
Paths are resolved to real paths (/var -> /private/var) because seatbelt
matches the resolved path.
"""
import os
import sys

sys.dont_write_bytecode = True


HOME_SECRETS = (".ssh", ".aws", ".gnupg", ".config/gh", ".config/gcloud", ".netrc", ".npmrc", ".docker", ".kube",
                ".claude", ".claude.json", ".codex", "Library/Keychains")


def main():
    if len(sys.argv) < 6 or sys.argv[5] not in ("read-only", "workspace-write"):
        print("usage: seatbelt.py <workdir> <home> <gocache> <tmpdir> <read-only|workspace-write> [--real-home H] [--repo R] [--task-dir T] [--deny-read P]...", file=sys.stderr)
        return 2
    workdir, home, gocache, tmpdir, mode = sys.argv[1:6]
    deny = []
    rest = sys.argv[6:]
    if len(rest) % 2:
        print("seatbelt.py: option without a value", file=sys.stderr)
        return 2
    for flag, val in zip(rest[0::2], rest[1::2]):
        if flag == "--real-home":
            deny += [os.path.join(val, h) for h in HOME_SECRETS]
        elif flag == "--repo":
            deny.append(os.path.join(val, "benchmarks", "eval", "corpus"))
        elif flag in ("--task-dir", "--deny-read"):
            deny.append(val)
        else:
            print("seatbelt.py: unknown option %s" % flag, file=sys.stderr)
            return 2
    denied = []
    for d in deny:
        r = os.path.realpath(d)
        if '"' in r or "\\" in r:
            print("seatbelt.py: refusing a path with a quote/backslash: %r" % r, file=sys.stderr)
            return 2
        denied.append(r)
    allowed = [home, gocache, tmpdir] + ([workdir] if mode == "workspace-write" else [])
    subs = []
    for p in allowed:
        os.makedirs(p, exist_ok=True)
        r = os.path.realpath(p)
        if '"' in r or "\\" in r:
            print("seatbelt.py: refusing a path with a quote/backslash: %r" % r, file=sys.stderr)
            return 2
        subs.append('(subpath "%s")' % r)
    for p in [workdir, home, gocache, tmpdir]:
        r = os.path.realpath(p)
        for d in denied:
            if r == d or r.startswith(d.rstrip("/") + "/"):
                print("seatbelt.py: cell path %s lies under denied-read path %s" % (r, d), file=sys.stderr)
                return 2
    print("(version 1)")
    print("(allow default)")
    print("(deny file-write*)")
    print("(allow file-write* %s" % " ".join(subs))
    print('  (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))')
    for d in denied:
        print('(deny file-read* (subpath "%s"))' % d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
