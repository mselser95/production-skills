"""Hour labels, the keys of the counter."""
from __future__ import annotations

from datetime import datetime, timezone


def as_utc(ts: datetime) -> datetime:
    """A naive timestamp is taken to be UTC, as every producer here writes UTC."""
    if ts.tzinfo is None:
        return ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc)


def hour_label(ts: datetime) -> str:
    """The UTC hour containing `ts`, as "2024-03-10T07:00Z"."""
    return as_utc(ts).strftime("%Y-%m-%dT%H:00Z")
