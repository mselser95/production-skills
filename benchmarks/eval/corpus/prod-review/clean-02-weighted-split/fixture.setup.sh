#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/split.go b/split.go
index a80179f..db39ee6 100644
--- a/split.go
+++ b/split.go
@@ -1,10 +1,16 @@
 package split
 
-import "errors"
+import (
+	"errors"
+	"math"
+)
 
-// ErrInput is returned for a negative total or a bad party count.
+// ErrInput is returned for a negative total, a bad party count or bad weights.
 var ErrInput = errors.New("invalid split input")
 
+// ErrOverflow is returned when total*sum(weights) does not fit in an int64.
+var ErrOverflow = errors.New("split overflows int64")
+
 // Even divides total cents between n parties. The shares sum to total; the
 // first total%n parties get one extra cent.
 func Even(total int64, n int) ([]int64, error) {
@@ -21,3 +27,39 @@ func Even(total int64, n int) ([]int64, error) {
 	}
 	return out, nil
 }
+
+// Weighted divides total cents in proportion to weights. Each share is rounded
+// down; the cents left over go one each to the earliest parties with a
+// positive weight, so the shares always sum to total and a zero weight always
+// gets zero.
+func Weighted(total int64, weights []int64) ([]int64, error) {
+	if total < 0 || len(weights) == 0 {
+		return nil, ErrInput
+	}
+	var sum int64
+	for _, w := range weights {
+		if w < 0 || w > math.MaxInt64-sum {
+			return nil, ErrInput
+		}
+		sum += w
+	}
+	if sum == 0 {
+		return nil, ErrInput
+	}
+	if total > math.MaxInt64/sum {
+		return nil, ErrOverflow
+	}
+	out := make([]int64, len(weights))
+	var given int64
+	for i, w := range weights {
+		out[i] = total * w / sum
+		given += out[i]
+	}
+	for left, i := total-given, 0; left > 0; i = (i + 1) % len(out) {
+		if weights[i] > 0 {
+			out[i]++
+			left--
+		}
+	}
+	return out, nil
+}
PATCH_EOF
