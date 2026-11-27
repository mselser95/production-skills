#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/file.go b/file.go
index 6f82973..593fa5c 100644
--- a/file.go
+++ b/file.go
@@ -1,12 +1,29 @@
 package auditlog
 
-import "os"
+import (
+	"fmt"
+	"os"
+)
 
 // OpenFile opens path for appending, creating it if needed.
-func OpenFile(path string) (*Log, error) {
+func OpenFile(path string) (l *Log, err error) {
 	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
 	if err != nil {
 		return nil, err
 	}
+	defer func() {
+		if err != nil {
+			// Best effort: err is already being returned and explains why the
+			// log is unusable; a failed close of a file we discard adds nothing.
+			_ = f.Close()
+		}
+	}()
+	info, err := f.Stat()
+	if err != nil {
+		return nil, err
+	}
+	if !info.Mode().IsRegular() {
+		return nil, fmt.Errorf("auditlog: %s is not a regular file", path)
+	}
 	return New(f), nil
 }
diff --git a/log.go b/log.go
index 6b8ed4a..afb239d 100644
--- a/log.go
+++ b/log.go
@@ -58,7 +58,8 @@ func (l *Log) Flush() error {
 	return l.w.Flush()
 }
 
-// Close flushes buffered entries and stops accepting new ones.
+// Close flushes buffered entries, stops accepting new ones and closes the
+// destination if it is an io.Closer, even when the flush failed.
 func (l *Log) Close() error {
 	l.mu.Lock()
 	defer l.mu.Unlock()
@@ -66,5 +67,15 @@ func (l *Log) Close() error {
 		return nil
 	}
 	l.closed = true
-	return l.w.Flush()
+	err := l.w.Flush()
+	c, ok := l.dst.(io.Closer)
+	if !ok {
+		return err
+	}
+	// A flush error is the primary failure and is returned as it is; a close
+	// error that follows it is a consequence, so only a clean flush reports it.
+	if cerr := c.Close(); err == nil {
+		err = cerr
+	}
+	return err
 }
PATCH_EOF
