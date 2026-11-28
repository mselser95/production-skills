"""Configuration: the ONLY module that reads the process environment.

(tests/architecture/test_boundaries.py fails if any other source file touches os.environ.)
"""

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field

MAX_PORT = 65535
MAX_PORT_DIGITS = 5
_PORT_TEXT = re.compile(rf"[0-9]{{1,{MAX_PORT_DIGITS}}}", re.ASCII)
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
    # Bound the length BEFORE int(): a 5000-digit string would raise (the int-string limit).
    if _PORT_TEXT.fullmatch(port_text) and int(port_text) <= MAX_PORT:
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
