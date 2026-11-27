#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/publish.go b/publish.go
new file mode 100644
index 0000000..6a22ccf
--- /dev/null
+++ b/publish.go
@@ -0,0 +1,33 @@
+package events
+
+func (b *Bus) snapshot(topic string) []subscription {
+	b.mu.Lock()
+	defer b.mu.Unlock()
+	return append([]subscription(nil), b.subs[topic]...)
+}
+
+// Publish delivers e to every handler subscribed to e.Topic and returns how
+// many it called. The lock is released before any handler runs, on purpose: a
+// handler may call Subscribe, Unsubscribe or Publish without deadlocking. A
+// handler removed after the snapshot was taken can still see this one event.
+func (b *Bus) Publish(e Event) int {
+	subs := b.snapshot(e.Topic)
+	for _, s := range subs {
+		s.fn(e)
+	}
+	return len(subs)
+}
+
+// PublishAsync delivers e from one new goroutine and returns a channel that is
+// closed once every handler has returned; that goroutine exits right after.
+func (b *Bus) PublishAsync(e Event) <-chan struct{} {
+	subs := b.snapshot(e.Topic)
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		for _, s := range subs {
+			s.fn(e)
+		}
+	}()
+	return done
+}
PATCH_EOF
