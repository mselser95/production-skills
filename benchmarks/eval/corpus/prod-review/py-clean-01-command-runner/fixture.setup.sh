#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/cmdrun/runner.py b/cmdrun/runner.py
index e7bde3b..7fdff33 100644
--- a/cmdrun/runner.py
+++ b/cmdrun/runner.py
@@ -3,6 +3,7 @@ from __future__ import annotations
 
 import subprocess
 from collections.abc import Sequence
+from dataclasses import dataclass
 
 from cmdrun.errors import CommandError
 
@@ -17,3 +18,28 @@ def run(argv: Sequence[str], *, timeout: float) -> str:
     if done.returncode != 0:
         raise CommandError(argv, done.returncode, done.stderr)
     return done.stdout
+
+
+@dataclass(frozen=True)
+class Completed:
+    returncode: int
+    stdout: str
+    stderr: str
+
+
+def run_capture(argv: Sequence[str], data: bytes = b"", *, timeout: float) -> Completed:
+    """Feed `data` to `argv` (no shell); a non-zero exit is returned, not raised."""
+    if not argv:
+        raise ValueError("argv must not be empty")
+    # Leaving the `with` closes the pipes and reaps the child, so no zombie is left.
+    with subprocess.Popen(
+        list(argv), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
+    ) as proc:
+        try:
+            out, err = proc.communicate(data, timeout=timeout)
+        except BaseException:
+            # Timeout or interrupt: never leave the child running, then let it propagate.
+            proc.kill()
+            raise
+    # Output is not ours to judge: undecodable bytes become U+FFFD, never an error.
+    return Completed(proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"))
PATCH_EOF
