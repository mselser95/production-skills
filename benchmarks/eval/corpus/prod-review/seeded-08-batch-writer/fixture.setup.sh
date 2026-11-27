#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/batcher.go b/batcher.go
index 6a22d4f..3802fdb 100644
--- a/batcher.go
+++ b/batcher.go
@@ -24,14 +24,25 @@ func New(max int, sink Sink) *Batcher {
 
 // Add queues item and flushes if the batch is full. If the flush fails the
 // items stay queued for the next attempt and the error is returned.
+//
+// The sink runs without the lock held, so a slow sink does not stall other
+// callers of Add.
 func (b *Batcher) Add(item string) error {
 	b.mu.Lock()
-	defer b.mu.Unlock()
 	b.buf = append(b.buf, item)
 	if len(b.buf) < b.max {
+		b.mu.Unlock()
 		return nil
 	}
-	return b.flushLocked()
+	batch := b.buf
+	b.buf = nil
+	b.mu.Unlock()
+	if err := b.sink(batch); err != nil {
+		b.mu.Lock()
+		b.buf = append(batch, b.buf...)
+		return err
+	}
+	return nil
 }
 
 // Flush sends whatever is queued, even if the batch is not full.
PATCH_EOF
