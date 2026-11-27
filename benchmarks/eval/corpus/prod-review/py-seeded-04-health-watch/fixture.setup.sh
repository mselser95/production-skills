#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/poller/probe.py b/poller/probe.py
index 9a865d0..ce63ce7 100644
--- a/poller/probe.py
+++ b/poller/probe.py
@@ -1,4 +1,4 @@
-"""Probing a service."""
+"""Probing a service: once, until ready, and over time."""
 from __future__ import annotations
 
 import asyncio
@@ -25,3 +25,28 @@ async def wait_ready(check: Check, *, interval: float, attempts: int, timeout: f
         if attempt < attempts - 1:
             await asyncio.sleep(interval)
     return False
+
+
+async def watch(
+    check: Check,
+    *,
+    interval: float,
+    timeout: float,
+    deadline: float,
+    on_change: Callable[[bool], None],
+) -> None:
+    """Probe every `interval` seconds for `deadline` seconds; call `on_change` on each flip."""
+    # `last` starts unknown, so the first probe always reports.
+    last: bool | None = None
+    try:
+        # One budget for the whole watch; each probe keeps its own timeout.
+        async with asyncio.timeout(deadline):
+            while True:
+                healthy = await probe_once(check, timeout)
+                if healthy != last:
+                    on_change(healthy)
+                    last = healthy
+                await asyncio.sleep(interval)
+    except (TimeoutError, asyncio.CancelledError):
+        # Out of time, or asked to stop: either way the watch is over.
+        return
PATCH_EOF
