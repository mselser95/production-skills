#!/usr/bin/env python3
"""runenv.py --cwd DIR --home DIR --gocache DIR [--tmpdir DIR] [--set K=V]... [--pass NAME]... -- cmd [args...]

THE one place that decides what environment an agent host starts with. The
caller's environment is never inherited: a host launched from inside a Claude
Code session would otherwise see CLAUDECODE, CLAUDE_CODE_SESSION_ID, the
messaging socket/token, OLDPWD pointing at the repo, ... and behave (and leak)
accordingly. The host gets only:
  - the allowlist below, copied from the caller if set;
  - HOME and GOCACHE of this cell, GOTOOLCHAIN=local and GOPROXY=off (nothing
    reaches the network through the go tool);
  - --set K=V pairs (non-secret: the host's config-dir var);
  - --pass NAME: a SECRET passed by NAME so its value never appears in any argv
    (ps) or trace -- at most the one auth variable.
cwd is set BEFORE exec so PWD is the workdir and no OLDPWD exists.
"""
import argparse
import os
import sys

ALLOW = ("PATH", "TMPDIR", "LANG", "LC_ALL", "TERM")
FIXED = {"GOTOOLCHAIN": "local", "GOPROXY": "off"}


def main():
    argv = sys.argv[1:]
    if "--" not in argv:
        print("runenv.py: missing -- before the command", file=sys.stderr)
        return 2
    i = argv.index("--")
    p = argparse.ArgumentParser()
    p.add_argument("--cwd", required=True)
    p.add_argument("--home", required=True)
    p.add_argument("--gocache", required=True)
    p.add_argument("--tmpdir")
    p.add_argument("--set", action="append", default=[])
    p.add_argument("--pass", action="append", default=[], dest="passed")
    a = p.parse_args(argv[:i])
    cmd = argv[i + 1:]
    if not cmd:
        print("runenv.py: no command", file=sys.stderr)
        return 2
    env = {k: os.environ[k] for k in ALLOW if k in os.environ}
    env.update(FIXED)
    env["HOME"] = a.home
    env["GOCACHE"] = a.gocache
    env["PWD"] = a.cwd
    if a.tmpdir:
        os.makedirs(a.tmpdir, exist_ok=True)
        env["TMPDIR"] = a.tmpdir   # per-cell TMPDIR: the one temp dir the sandbox lets the agent write
    for kv in a.set:
        k, _, v = kv.partition("=")
        env[k] = v
    for name in a.passed:
        if name in os.environ:
            env[name] = os.environ[name]
    os.makedirs(a.gocache, exist_ok=True)
    os.chdir(a.cwd)
    try:
        os.execvpe(cmd[0], cmd, env)
    except OSError as e:
        print("runenv.py: cannot exec %s: %s" % (cmd[0], e), file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main())
