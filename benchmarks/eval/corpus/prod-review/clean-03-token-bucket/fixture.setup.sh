#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/bucket.go b/bucket.go
index d357921..0b40bbb 100644
--- a/bucket.go
+++ b/bucket.go
@@ -3,6 +3,7 @@ package bucket
 
 import (
 	"errors"
+	"math"
 	"sync"
 	"time"
 )
@@ -16,19 +17,22 @@ type Bucket struct {
 	now      func() time.Time
 	capacity int64
 	perSec   int64
+	fill     time.Duration // time to refill an empty bucket, rounded up
+	rem      int64         // earned but unspent fraction of a token, in 1e-9
 	tokens   int64
 	last     time.Time
 }
 
 // New returns a full Bucket. now is the clock; nil means time.Now.
 func New(capacity, perSec int64, now func() time.Time) (*Bucket, error) {
-	if capacity < 1 || perSec < 1 {
+	if capacity < 1 || perSec < 1 || perSec > int64(time.Second) || capacity >= math.MaxInt64/int64(time.Second) {
 		return nil, ErrConfig
 	}
 	if now == nil {
 		now = time.Now
 	}
-	return &Bucket{now: now, capacity: capacity, perSec: perSec, tokens: capacity, last: now()}, nil
+	fill := time.Duration((capacity*int64(time.Second) + perSec - 1) / perSec)
+	return &Bucket{now: now, capacity: capacity, perSec: perSec, fill: fill, tokens: capacity, last: now()}, nil
 }
 
 // Allow takes n tokens if they are available and reports whether it did.
@@ -46,12 +50,25 @@ func (b *Bucket) Allow(n int64) bool {
 	return true
 }
 
-// refill credits whole seconds only, so a sub-second wait earns nothing.
+// refill credits tokens for the time since the last call, to the nanosecond.
+// rem carries the part of a token not yet earned, in billionths, so frequent
+// callers lose nothing and an idle bucket cannot earn more than it holds.
 func (b *Bucket) refill(now time.Time) {
-	secs := int64(now.Sub(b.last) / time.Second)
-	if secs <= 0 {
+	elapsed := now.Sub(b.last)
+	if elapsed <= 0 {
 		return
 	}
-	b.tokens = min(b.capacity, b.tokens+secs*b.perSec)
-	b.last = b.last.Add(time.Duration(secs) * time.Second)
+	b.last = now
+	// Idle for fill or longer means full. Below fill, elapsed*perSec stays under
+	// capacity*1e9, which New bounds so that the sum below fits an int64.
+	if elapsed >= b.fill {
+		b.tokens, b.rem = b.capacity, 0
+		return
+	}
+	acc := int64(elapsed)*b.perSec + b.rem
+	b.tokens += acc / int64(time.Second)
+	b.rem = acc % int64(time.Second)
+	if b.tokens >= b.capacity {
+		b.tokens, b.rem = b.capacity, 0
+	}
 }
PATCH_EOF
