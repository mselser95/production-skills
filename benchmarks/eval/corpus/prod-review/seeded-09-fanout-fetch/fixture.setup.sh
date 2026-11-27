#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/fetch.go b/fetch.go
index 6acbdfb..505c679 100644
--- a/fetch.go
+++ b/fetch.go
@@ -6,8 +6,11 @@ import (
 	"errors"
 	"sort"
 	"sync"
+	"time"
 )
 
+const maxBackoff = 30 * time.Second
+
 // Item is one search hit.
 type Item struct {
 	ID    string
@@ -21,6 +24,7 @@ type Backend func(ctx context.Context, query string) ([]Item, error)
 type Fetcher struct {
 	backends []Backend
 	attempts int
+	backoff  time.Duration
 }
 
 // New returns a Fetcher that tries each backend up to attempts times.
@@ -31,6 +35,14 @@ func New(attempts int, backends ...Backend) *Fetcher {
 	return &Fetcher{backends: backends, attempts: attempts}
 }
 
+// WithBackoff makes a retry wait base after the first failure, then double
+// the wait after each further failure, never longer than 30 seconds. Zero
+// (the default) retries at once. It returns f so calls can be chained.
+func (f *Fetcher) WithBackoff(base time.Duration) *Fetcher {
+	f.backoff = base
+	return f
+}
+
 // Fetch queries all backends concurrently and returns the merged hits, best
 // score first. A backend that fails is skipped; the call fails only when
 // every backend failed.
@@ -86,6 +98,20 @@ func (f *Fetcher) call(ctx context.Context, b Backend, query string) ([]Item, er
 		if items, err = b(ctx, query); err == nil {
 			return items, nil
 		}
+		// Give the backend room to recover before the next attempt.
+		if i+1 < f.attempts && f.backoff > 0 {
+			time.Sleep(f.delay(i))
+		}
 	}
 	return nil, err
 }
+
+// delay is the wait after failure number i (0-based): backoff, doubled i
+// times, capped at maxBackoff.
+func (f *Fetcher) delay(i int) time.Duration {
+	d := f.backoff
+	for ; i > 0 && d < maxBackoff; i-- {
+		d *= 2
+	}
+	return min(d, maxBackoff)
+}
PATCH_EOF
