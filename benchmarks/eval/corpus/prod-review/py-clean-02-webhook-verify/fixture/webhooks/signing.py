"""Webhook signatures: HMAC-SHA256 over "<timestamp>.<body>", sent as "t=<ts>,v1=<hex>"."""
from __future__ import annotations

import hashlib
import hmac


def sign(secret: bytes, timestamp: int, body: bytes) -> str:
    """Hex HMAC-SHA256 of the timestamp and the exact body bytes."""
    if timestamp < 0:
        raise ValueError("timestamp must not be negative")
    message = str(timestamp).encode("ascii") + b"." + body
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def header(secret: bytes, timestamp: int, body: bytes) -> str:
    """The signature header for a delivery made at `timestamp`."""
    return f"t={timestamp},v1={sign(secret, timestamp, body)}"
