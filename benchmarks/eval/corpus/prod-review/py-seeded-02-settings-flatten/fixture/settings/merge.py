"""Layer merging and the built-in defaults."""
from __future__ import annotations

from collections.abc import Mapping

DEFAULTS: dict[str, str] = {
    "db.host": "localhost",
    "db.port": "5432",
    "log.level": "info",
}


def merge(*layers: Mapping[str, str]) -> dict[str, str]:
    """Later layers win; the inputs are never modified."""
    out: dict[str, str] = {}
    for layer in layers:
        out.update(layer)
    return out
