#!/usr/bin/env python3
"""limited.py <seconds> -- cmd [args...]

Portable watchdog (macOS has no guaranteed `timeout`). Runs cmd as the leader
of its OWN process group and kills the WHOLE group when the limit passes, and
also when cmd exits normally, so a host that leaves a background child behind
cannot leak it into the next cell.

Exit: 124 timed out (group killed) | 127 cannot start | else cmd's exit code.
"""
import os
import signal
import subprocess
import sys
import time


def kill_group(pgid, grace=2.0):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            return
        deadline = time.time() + (grace if sig == signal.SIGTERM else 0.5)
        while time.time() < deadline:
            try:
                os.killpg(pgid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.05)


def main():
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print("usage: limited.py <seconds> -- cmd [args...]", file=sys.stderr)
        return 2
    limit = float(sys.argv[1])
    try:
        proc = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        print("limited.py: cannot start %s: %s" % (sys.argv[3], e), file=sys.stderr)
        return 127
    pgid = proc.pid

    def forward(_sig, _frm):
        kill_group(pgid)
        os._exit(143)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    try:
        rc = proc.wait(timeout=limit)
        kill_group(pgid)  # stragglers of a finished leader
        return rc if rc >= 0 else 128 - rc
    except subprocess.TimeoutExpired:
        kill_group(pgid)
        proc.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
