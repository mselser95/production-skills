"""Errors raised by the runner."""
from __future__ import annotations

from collections.abc import Sequence


class CommandError(Exception):
    """A command ran and failed; carries what is needed to report it."""

    def __init__(self, argv: Sequence[str], returncode: int, stderr: str) -> None:
        super().__init__(f"{argv[0]} exited with {returncode}: {stderr.strip()[:200]}")
        self.argv = list(argv)
        self.returncode = returncode
        self.stderr = stderr
