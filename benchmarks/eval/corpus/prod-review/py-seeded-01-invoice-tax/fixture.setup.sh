#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/invoicing/lines.py b/invoicing/lines.py
index 642df86..68581f1 100644
--- a/invoicing/lines.py
+++ b/invoicing/lines.py
@@ -1,11 +1,11 @@
 """Invoice lines and their totals."""
 from __future__ import annotations
 
-from collections.abc import Iterable
+from collections.abc import Iterable, Sequence
 from dataclasses import dataclass
 from decimal import Decimal
 
-from invoicing.money import to_cents
+from invoicing.money import CENT, to_cents
 
 
 @dataclass(frozen=True)
@@ -25,3 +25,19 @@ def line_total(line: Line) -> Decimal:
 def subtotal(lines: Iterable[Line]) -> Decimal:
     """Sum of the line totals."""
     return sum((line_total(line) for line in lines), Decimal(0))
+
+
+def line_tax(line: Line, rate: Decimal) -> Decimal:
+    """Tax on one line at `rate` (0.2 means 20%), in whole cents."""
+    if rate < 0:
+        raise ValueError("tax rate must not be negative")
+    # Tax is taken on the rounded line total, not on the raw product.
+    return (line_total(line) * rate).quantize(CENT)
+
+
+def invoice_total(lines: Sequence[Line], rate: Decimal) -> Decimal:
+    """Net plus tax, in whole cents."""
+    # Tax is rounded per line so the printed lines add up to the printed total.
+    tax = sum((line_tax(line, rate) for line in lines), Decimal(0))
+    # A zero rate is allowed and yields zero tax.
+    return to_cents(subtotal(lines) + tax)
PATCH_EOF
