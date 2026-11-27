#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/retry.go b/retry.go
index b7fd310..db21286 100644
--- a/retry.go
+++ b/retry.go
@@ -1,23 +1,76 @@
 package retry
 
 import (
+	"bytes"
 	"context"
 	"errors"
 	"fmt"
+	"sync"
 	"time"
 )
 
 // ErrExhausted wraps the last error once every attempt has failed.
 var ErrExhausted = errors.New("retry: attempts exhausted")
 
-// Policy bounds a retry loop.
+// Policy bounds a retry loop; the wait doubles up to MaxDelay (zero: constant).
 type Policy struct {
 	Attempts int
 	Delay    time.Duration
+	MaxDelay time.Duration
 }
 
-// Do calls fn up to p.Attempts times, sleeping p.Delay between failures.
+// wait returns how long to sleep after the given (0-based) failed attempt.
+func (p Policy) wait(attempt int) time.Duration {
+	d := p.Delay
+	if d <= 0 {
+		return 0
+	}
+	if p.MaxDelay <= 0 {
+		return d
+	}
+	for i := 0; i < attempt && d < p.MaxDelay; i++ {
+		if d > p.MaxDelay/2 {
+			return p.MaxDelay
+		}
+		d *= 2
+	}
+	if d > p.MaxDelay {
+		return p.MaxDelay
+	}
+	return d
+}
+
+// Recorder keeps the errors seen by Do; it is safe for concurrent use.
+type Recorder struct {
+	mu   sync.Mutex
+	errs []string
+}
+
+func (r *Recorder) add(err error) {
+	r.mu.Lock()
+	defer r.mu.Unlock()
+	r.errs = append(r.errs, err.Error())
+}
+
+// Summary renders the recorded errors, one per line.
+func (r *Recorder) Summary() string {
+	r.mu.Lock()
+	snap := append([]string(nil), r.errs...)
+	r.mu.Unlock()
+	var b bytes.Buffer
+	for i, e := range snap {
+		_, _ = fmt.Fprintf(&b, "%d: %s\n", i+1, e)
+	}
+	return b.String()
+}
+
+// Do calls fn up to p.Attempts times, waiting between failures until ctx is done.
 func Do(ctx context.Context, p Policy, fn func(context.Context) error) error {
+	return DoRecorded(ctx, p, nil, fn)
+}
+
+// DoRecorded is Do that also records every failure in rec; rec may be nil.
+func DoRecorded(ctx context.Context, p Policy, rec *Recorder, fn func(context.Context) error) error {
 	var last error
 	for i := 0; i < p.Attempts; i++ {
 		if err := ctx.Err(); err != nil {
@@ -26,7 +79,19 @@ func Do(ctx context.Context, p Policy, fn func(context.Context) error) error {
 		if last = fn(ctx); last == nil {
 			return nil
 		}
-		time.Sleep(p.Delay)
+		if rec != nil {
+			rec.add(last)
+		}
+		if i == p.Attempts-1 {
+			break
+		}
+		t := time.NewTimer(p.wait(i))
+		select {
+		case <-ctx.Done():
+			t.Stop()
+			return ctx.Err()
+		case <-t.C:
+		}
 	}
 	return fmt.Errorf("%w: %v", ErrExhausted, last)
 }
PATCH_EOF
