#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/runall.go b/runall.go
new file mode 100644
index 0000000..e379613
--- /dev/null
+++ b/runall.go
@@ -0,0 +1,52 @@
+package jobs
+
+import (
+	"context"
+	"sync"
+	"sync/atomic"
+)
+
+// RunAll runs jobs on up to workers goroutines and returns once every worker
+// has exited. The first job error cancels the context the other jobs see and is
+// returned. If the caller's ctx ends before every job has run, RunAll returns
+// ctx.Err(); a job that was already running is left to notice ctx itself.
+func RunAll(ctx context.Context, workers int, jobs []Job) error {
+	if workers < 1 {
+		return ErrWorkers
+	}
+	parent := ctx
+	ctx, cancel := context.WithCancel(parent)
+	defer cancel() // after Wait: it only releases the derived context
+
+	var (
+		next, done atomic.Int64
+		once       sync.Once
+		first      error
+		wg         sync.WaitGroup
+	)
+	for w := 0; w < min(workers, len(jobs)); w++ {
+		wg.Add(1)
+		go func() {
+			defer wg.Done()
+			for ctx.Err() == nil {
+				i := int(next.Add(1)) - 1
+				if i >= len(jobs) {
+					return
+				}
+				if err := jobs[i](ctx); err != nil {
+					once.Do(func() { first = err; cancel() })
+					return
+				}
+				done.Add(1)
+			}
+		}()
+	}
+	wg.Wait()
+	if first != nil {
+		return first
+	}
+	if int(done.Load()) < len(jobs) {
+		return parent.Err()
+	}
+	return nil
+}
PATCH_EOF
