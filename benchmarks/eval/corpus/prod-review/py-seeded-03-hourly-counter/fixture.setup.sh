#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/windows/counter.py b/windows/counter.py
index d3685f7..2a9254c 100644
--- a/windows/counter.py
+++ b/windows/counter.py
@@ -3,7 +3,7 @@ from __future__ import annotations
 
 from datetime import datetime
 
-from windows.labels import hour_label
+from windows.labels import Clock, hour_label, recent_labels
 
 
 class HourlyCounter:
@@ -22,3 +22,8 @@ class HourlyCounter:
     def snapshot(self) -> dict[str, int]:
         """A copy, ordered by hour."""
         return dict(sorted(self._counts.items()))
+
+    def recent_total(self, n: int, clock: Clock | None = None) -> int:
+        """Events recorded in the last `n` hours, the hour in progress included."""
+        # Hours with no events simply contribute zero.
+        return sum(self.count(label) for label in recent_labels(n, clock))
diff --git a/windows/labels.py b/windows/labels.py
index 48dc7f1..f9f7897 100644
--- a/windows/labels.py
+++ b/windows/labels.py
@@ -1,7 +1,10 @@
 """Hour labels, the keys of the counter."""
 from __future__ import annotations
 
-from datetime import datetime, timezone
+from collections.abc import Callable
+from datetime import datetime, timedelta, timezone
+
+Clock = Callable[[], datetime]
 
 
 def as_utc(ts: datetime) -> datetime:
@@ -14,3 +17,23 @@ def as_utc(ts: datetime) -> datetime:
 def hour_label(ts: datetime) -> str:
     """The UTC hour containing `ts`, as "2024-03-10T07:00Z"."""
     return as_utc(ts).strftime("%Y-%m-%dT%H:00Z")
+
+
+def _now(clock: Clock | None) -> datetime:
+    """The injected clock, else the wall clock."""
+    # Production code passes no clock; tests pass a fixed one.
+    return clock() if clock is not None else datetime.now()
+
+
+def current_label(clock: Clock | None = None) -> str:
+    """Label of the hour in progress."""
+    return hour_label(_now(clock))
+
+
+def recent_labels(n: int, clock: Clock | None = None) -> list[str]:
+    """The last `n` labels, oldest first, ending with the hour in progress."""
+    if n < 1:
+        raise ValueError("n must be at least 1")
+    # Step back whole hours from the top of the current hour.
+    top = as_utc(_now(clock)).replace(minute=0, second=0, microsecond=0)
+    return [hour_label(top - timedelta(hours=i)) for i in range(n - 1, -1, -1)]
PATCH_EOF
