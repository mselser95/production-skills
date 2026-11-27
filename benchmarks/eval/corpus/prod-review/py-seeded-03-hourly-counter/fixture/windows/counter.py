"""Counts per UTC hour."""
from __future__ import annotations

from datetime import datetime

from windows.labels import hour_label


class HourlyCounter:
    def __init__(self) -> None:
        self._counts: dict[str, int] = {}

    def record(self, ts: datetime, n: int = 1) -> None:
        if n < 1:
            raise ValueError("n must be at least 1")
        label = hour_label(ts)
        self._counts[label] = self._counts.get(label, 0) + n

    def count(self, label: str) -> int:
        return self._counts.get(label, 0)

    def snapshot(self) -> dict[str, int]:
        """A copy, ordered by hour."""
        return dict(sorted(self._counts.items()))
