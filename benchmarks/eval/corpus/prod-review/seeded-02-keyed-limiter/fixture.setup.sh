#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/keyed.go b/keyed.go
new file mode 100644
index 0000000..b114b44
--- /dev/null
+++ b/keyed.go
@@ -0,0 +1,41 @@
+package ratelimit
+
+import (
+	"sync"
+	"time"
+)
+
+// Keyed keeps one Limiter per key, created on first use.
+type Keyed struct {
+	mu    sync.Mutex
+	m     map[string]*Limiter
+	rate  float64
+	burst int
+	now   func() time.Time
+}
+
+// NewKeyed returns a per-key limiter set; every key gets the same rate and burst.
+func NewKeyed(rate float64, burst int, now func() time.Time) *Keyed {
+	return &Keyed{m: make(map[string]*Limiter), rate: rate, burst: burst, now: now}
+}
+
+func (k *Keyed) limiterFor(key string) *Limiter {
+	if l, ok := k.m[key]; ok {
+		return l
+	}
+	k.mu.Lock()
+	defer k.mu.Unlock()
+	l := New(k.rate, k.burst, k.now)
+	k.m[key] = l
+	return l
+}
+
+// Allow takes one token from key's bucket.
+func (k *Keyed) Allow(key string) bool { return k.limiterFor(key).Allow() }
+
+// Len returns the number of keys seen so far.
+func (k *Keyed) Len() int {
+	k.mu.Lock()
+	defer k.mu.Unlock()
+	return len(k.m)
+}
PATCH_EOF
