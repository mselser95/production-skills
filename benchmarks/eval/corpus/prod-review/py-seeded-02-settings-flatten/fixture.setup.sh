#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/settings/sources.py b/settings/sources.py
index c4ec983..a0548b0 100644
--- a/settings/sources.py
+++ b/settings/sources.py
@@ -1,7 +1,9 @@
-"""Setting sources: the environment."""
+"""Setting sources: the environment and TOML documents."""
 from __future__ import annotations
 
+import tomllib
 from collections.abc import Mapping
+from typing import Any
 
 from settings.merge import DEFAULTS, merge
 
@@ -18,3 +20,28 @@ def from_environ(environ: Mapping[str, str], prefix: str = "APP_") -> dict[str,
 def resolve(environ: Mapping[str, str]) -> dict[str, str]:
     """The defaults overridden by the environment."""
     return merge(DEFAULTS, from_environ(environ))
+
+
+def _leaf(value: Any) -> str:
+    # The environment layer spells booleans in lower case, so the file layer does too.
+    if isinstance(value, bool):
+        return "true" if value else "false"
+    return str(value)
+
+
+# Keys are joined with dots, matching the names the environment layer builds.
+def flatten(tree: Mapping[str, Any], prefix: str = "", out: dict[str, str] = {}) -> dict[str, str]:
+    """{"db": {"host": "x"}} becomes {"db.host": "x"}; other leaves are text."""
+    for key, value in tree.items():
+        path = prefix + key
+        if isinstance(value, Mapping):
+            flatten(value, path + ".", out)
+        else:
+            out[path] = _leaf(value)
+    return out
+
+
+def from_toml(text: str) -> dict[str, str]:
+    """Parse a TOML document into the dotted key space the environment layer uses."""
+    # tomllib raises TOMLDecodeError (a ValueError) on a bad document; let it through.
+    return flatten(tomllib.loads(text))
PATCH_EOF
