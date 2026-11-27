#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/shutdown.go b/shutdown.go
new file mode 100644
index 0000000..680fe07
--- /dev/null
+++ b/shutdown.go
@@ -0,0 +1,29 @@
+package drain
+
+import "context"
+
+// Shutdown stops accepting new jobs and waits for the running ones until ctx
+// ends. If ctx ends first it cancels the context the jobs see and returns
+// ctx.Err() without waiting further. It may be called more than once.
+func (c *Coordinator) Shutdown(ctx context.Context) error {
+	c.mu.Lock()
+	c.closed = true // under mu: every wg.Add in Go happens before the Wait below
+	c.mu.Unlock()
+
+	// Buffered on purpose: if we return on ctx.Done nobody receives, and the
+	// waiter must still be able to send and exit once the jobs finish.
+	drained := make(chan struct{}, 1)
+	go func() {
+		c.wg.Wait()
+		drained <- struct{}{}
+	}()
+
+	select {
+	case <-drained:
+		c.cancel()
+		return nil
+	case <-ctx.Done():
+		c.cancel()
+		return ctx.Err()
+	}
+}
PATCH_EOF
