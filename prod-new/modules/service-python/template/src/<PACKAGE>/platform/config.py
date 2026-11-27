"""Configuration: the ONLY module that reads the process environment.

(tests/architecture/test_boundaries.py fails if any other source file touches os.environ.)
"""

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field

MIN_TOKEN_LENGTH = 32
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9._~+/=-]{32,}", re.ASCII)


class ConfigError(ValueError):
    """The environment does not describe a runnable service; the message lists every problem."""


@dataclass(frozen=True, slots=True)
class Config:
    host: str
    port: int
    api_token: str = field(repr=False)
    revision: str


def load(environ: Mapping[str, str] | None = None) -> Config:
    """Read SVC_HOST, SVC_PORT, SVC_API_TOKEN (required) and SVC_REVISION."""
    env = os.environ if environ is None else environ
    problems: list[str] = []
    host = env.get("SVC_HOST", "127.0.0.1")
    port_text = env.get("SVC_PORT", "8080")
    port = 0
    if port_text.isascii() and port_text.isdigit() and 0 <= int(port_text) <= 65535:  # noqa: PLR2004
        port = int(port_text)
    else:
        problems.append("SVC_PORT must be an integer in 0..65535")
    token = env.get("SVC_API_TOKEN", "")
    if TOKEN_PATTERN.fullmatch(token) is None:
        problems.append(
            f"SVC_API_TOKEN is required: at least {MIN_TOKEN_LENGTH} characters from "
            "A-Z a-z 0-9 . _ ~ + / = - (no whitespace)"
        )
    if problems:
        raise ConfigError("; ".join(problems))
    return Config(host, port, token, env.get("SVC_REVISION", "unknown"))
