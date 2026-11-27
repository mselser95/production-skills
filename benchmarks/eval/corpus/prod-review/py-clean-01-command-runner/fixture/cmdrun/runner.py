"""Run a command without a shell."""
from __future__ import annotations

import subprocess
from collections.abc import Sequence

from cmdrun.errors import CommandError


def run(argv: Sequence[str], *, timeout: float) -> str:
    """Run `argv` (no shell) and return its stdout; a non-zero exit raises CommandError."""
    if not argv:
        raise ValueError("argv must not be empty")
    done = subprocess.run(
        list(argv), capture_output=True, text=True, timeout=timeout, check=False
    )
    if done.returncode != 0:
        raise CommandError(argv, done.returncode, done.stderr)
    return done.stdout
