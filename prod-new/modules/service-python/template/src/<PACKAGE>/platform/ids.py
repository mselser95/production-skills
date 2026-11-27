"""Real and deterministic id generators."""

import itertools
import uuid


class UuidIds:
    def new_id(self) -> str:
        return uuid.uuid4().hex


class SequenceIds:
    """ev-1, ev-2, ...: deterministic, for tests and simulations."""

    def __init__(self, prefix: str = "ev") -> None:
        self._prefix = prefix
        self._counter = itertools.count(1)

    def new_id(self) -> str:
        return f"{self._prefix}-{next(self._counter)}"
