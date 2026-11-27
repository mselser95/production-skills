"""Probing a service."""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

Check = Callable[[], Awaitable[bool]]


async def probe_once(check: Check, timeout: float) -> bool:
    """True when `check` answers True within `timeout` seconds; a timeout is False."""
    try:
        return await asyncio.wait_for(check(), timeout)
    except TimeoutError:
        return False


async def wait_ready(check: Check, *, interval: float, attempts: int, timeout: float) -> bool:
    """Probe up to `attempts` times, `interval` seconds apart; True on the first success."""
    if attempts < 1:
        raise ValueError("attempts must be at least 1")
    for attempt in range(attempts):
        if await probe_once(check, timeout):
            return True
        if attempt < attempts - 1:
            await asyncio.sleep(interval)
    return False
