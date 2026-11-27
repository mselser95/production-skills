#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/webhooks/signing.py b/webhooks/signing.py
index 0712809..4695b1b 100644
--- a/webhooks/signing.py
+++ b/webhooks/signing.py
@@ -16,3 +16,36 @@ def sign(secret: bytes, timestamp: int, body: bytes) -> str:
 def header(secret: bytes, timestamp: int, body: bytes) -> str:
     """The signature header for a delivery made at `timestamp`."""
     return f"t={timestamp},v1={sign(secret, timestamp, body)}"
+
+
+def parse_header(value: str) -> tuple[int, list[str]] | None:
+    """(timestamp, signatures) from "t=<ts>,v1=<hex>[,v1=<hex>...]", or None if malformed."""
+    stamps: list[str] = []
+    sigs: list[str] = []
+    for part in value.split(","):
+        name, sep, rest = part.strip().partition("=")
+        if not sep:
+            return None
+        if name == "t":
+            stamps.append(rest)
+        elif name == "v1":
+            sigs.append(rest)
+        # Other schemes (v0, v2, ...) are ignored so the sender can add new ones.
+    if len(stamps) != 1 or not sigs:
+        return None
+    stamp = stamps[0]
+    # A Unix time in seconds: ASCII digits only, short enough that int() stays cheap.
+    if not (stamp.isascii() and stamp.isdigit() and len(stamp) <= 12):
+        return None
+    return int(stamp), sigs
+
+
+def verify(secret: bytes, header: str, body: bytes, *, now: int, tolerance: int = 300) -> bool:
+    """True when a v1 signature matches and the timestamp is within `tolerance` seconds of `now`."""
+    parsed = parse_header(header)
+    if parsed is None or abs(now - parsed[0]) > tolerance:
+        return False
+    timestamp, candidates = parsed
+    expected = sign(secret, timestamp, body).encode("ascii")
+    # The list is built before any() runs, so every candidate is compared.
+    return any([hmac.compare_digest(expected, c.encode("utf-8", "replace")) for c in candidates])
PATCH_EOF
