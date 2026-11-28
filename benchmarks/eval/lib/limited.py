#!/usr/bin/env python3
"""limited.py [--capture OUT [--orphan FILE] [--stdin FILE] [--stderr FILE]] <seconds> -- cmd [args...]

Portable watchdog (macOS has no guaranteed `timeout`). Runs cmd as the leader
of its OWN process group and kills the WHOLE group when the limit passes, and
also when cmd exits normally, so a host that leaves a background child behind
cannot leak it into the next cell.

Exit: 124 timed out (group killed) | 127 cannot start | 143 TERM/INT, 129 HUP (group killed and reaped) | else cmd's exit code.

--capture OUT: cmd's stdout is read HERE (outside any sandbox the cmd runs under) into OUT, so the cmd never holds
a descriptor on a harness file. When the leader is gone the group is killed and the pipe gets ONE bounded grace
(GRACE seconds): a process that escaped the group (setsid) and still holds the pipe cannot keep the harness
waiting; the read end is closed and, when --orphan FILE is given, FILE is created ("orphan-process"). Detection
limit: an escaped process that does not hold the pipe is invisible (no pid is known), and it keeps running,
sandboxed and network-capable, until it exits or the user logs out. <seconds> 0 = no limit (an outer watchdog binds).
"""
import os
import signal
import select
import subprocess
import sys
import time


def kill_group(pgid, grace=2.0, leader=None):
    """TERM then KILL the group. `leader` (our own child, the group leader) is reaped while we wait: an unreaped zombie
    leader keeps killpg(pgid, 0) succeeding, so the wait would burn the whole grace, and when we exit right after (the
    signal path) it would be left for init -- which in a container without a reaper never collects it."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            return
        deadline = time.time() + (grace if sig == signal.SIGTERM else 0.5)
        while time.time() < deadline:
            if leader is not None:
                leader.poll()
            try:
                os.killpg(pgid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.05)


GRACE = 2.0


def capture_loop(proc, pgid, out_fd, limit, orphan_file):
    """copy proc's stdout to out_fd; returns (rc, timed_out)"""
    rfd = proc.stdout.fileno()
    start = time.time()
    gone_at = None
    timed_out = False
    killed = False
    while True:
        r, _, _ = select.select([rfd], [], [], 0.25)
        if r:
            chunk = os.read(rfd, 65536)
            if not chunk:
                break
            os.write(out_fd, chunk)
        now = time.time()
        if proc.poll() is not None and gone_at is None:
            gone_at = now
            kill_group(pgid, leader=proc)
            killed = True
        if limit and gone_at is None and now - start > limit and not killed:
            timed_out = True
            kill_group(pgid, leader=proc)
            killed = True
            gone_at = now
        if gone_at is not None and now - gone_at > GRACE:
            if orphan_file:
                open(orphan_file, "w").close()
            break
    proc.stdout.close()
    return timed_out


def main():
    argv = sys.argv[1:]
    cap = orphan = sin = serr = None
    while argv and argv[0] in ("--capture", "--orphan", "--stdin", "--stderr") and len(argv) > 1:
        k, v = argv[0], argv[1]
        argv = argv[2:]
        if k == "--capture":
            cap = v
        elif k == "--orphan":
            orphan = v
        elif k == "--stdin":
            sin = v
        else:
            serr = v
    if len(argv) < 3 or argv[1] != "--":
        print("usage: limited.py [--capture OUT [--orphan FILE] [--stdin FILE] [--stderr FILE]] <seconds> -- cmd [args...]", file=sys.stderr)
        return 2
    limit = float(argv[0])
    cmd = argv[2:]
    try:
        kw = {"stdin": open(sin, "rb") if sin else subprocess.DEVNULL, "start_new_session": True}
        if cap:
            kw["stdout"] = subprocess.PIPE
            out_fd = os.open(cap, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        if serr:
            kw["stderr"] = open(serr, "ab")
        proc = subprocess.Popen(cmd, **kw)
    except OSError as e:
        print("limited.py: cannot start %s: %s" % (cmd[0], e), file=sys.stderr)
        return 127
    pgid = proc.pid

    def forward(sig, _frm):
        # TERM/INT -> 143, HUP (a terminal hangup) -> 129: the child's group is taken down and REAPED either way (kill_group), so a
        # hangup that reaches only this watchdog cannot leave the CLI running under a cell that is then removed
        kill_group(pgid, leader=proc)
        os._exit(129 if sig == signal.SIGHUP else 143)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGHUP, forward)
    if cap:
        timed_out = capture_loop(proc, pgid, out_fd, limit, orphan)
        if timed_out:
            proc.wait()
            return 124
        rc = proc.wait()
        return rc if rc >= 0 else 128 - rc
    try:
        rc = proc.wait(timeout=limit or None)
        kill_group(pgid, leader=proc)  # stragglers of a finished leader
        return rc if rc >= 0 else 128 - rc
    except subprocess.TimeoutExpired:
        kill_group(pgid, leader=proc)
        proc.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
