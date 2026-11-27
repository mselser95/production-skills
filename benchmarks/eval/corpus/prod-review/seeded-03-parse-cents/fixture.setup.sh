#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/invoice.go b/invoice.go
index 9f801e1..aea6eeb 100644
--- a/invoice.go
+++ b/invoice.go
@@ -1,6 +1,14 @@
 package invoice
 
-import "fmt"
+import (
+	"errors"
+	"fmt"
+	"strconv"
+	"strings"
+)
+
+// ErrInput is returned for a malformed or out-of-range price or quantity.
+var ErrInput = errors.New("invalid input")
 
 // Line is one invoice line; prices are integer cents.
 type Line struct {
@@ -35,3 +43,24 @@ func (i Invoice) Tax(bps int64) int64 {
 func Format(cents int64) string {
 	return fmt.Sprintf("%d.%02d", cents/100, cents%100)
 }
+
+// ParseCents converts a decimal price such as "19.99" to integer cents.
+func ParseCents(s string) (int64, error) {
+	f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
+	if err != nil || f < 0 {
+		return 0, fmt.Errorf("%w: price %q", ErrInput, s)
+	}
+	return int64(f * 100), nil
+}
+
+// LineFromInput builds a Line from user-supplied strings.
+func LineFromInput(desc, price string, qty int64) (Line, error) {
+	if qty <= 0 {
+		return Line{}, fmt.Errorf("%w: quantity %d", ErrInput, qty)
+	}
+	c, err := ParseCents(price)
+	if err != nil {
+		return Line{}, err
+	}
+	return Line{Desc: strings.TrimSpace(desc), UnitCents: c, Qty: qty}, nil
+}
PATCH_EOF
