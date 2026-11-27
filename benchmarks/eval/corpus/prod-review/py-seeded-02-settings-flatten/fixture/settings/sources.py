"""Setting sources: the environment."""
from __future__ import annotations

from collections.abc import Mapping

from settings.merge import DEFAULTS, merge


def from_environ(environ: Mapping[str, str], prefix: str = "APP_") -> dict[str, str]:
    """APP_DB_HOST=x becomes {"db.host": "x"}; other variables are ignored."""
    out: dict[str, str] = {}
    for name, value in environ.items():
        if name.startswith(prefix) and len(name) > len(prefix):
            out[name[len(prefix):].lower().replace("_", ".")] = value
    return out


def resolve(environ: Mapping[str, str]) -> dict[str, str]:
    """The defaults overridden by the environment."""
    return merge(DEFAULTS, from_environ(environ))
