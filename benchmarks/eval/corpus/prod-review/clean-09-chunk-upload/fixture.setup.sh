#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/upload.go b/upload.go
index 3dc8b8f..446e3e2 100644
--- a/upload.go
+++ b/upload.go
@@ -9,7 +9,7 @@ import (
 
 var (
 	ErrChunkSize  = errors.New("upload: chunk size must be positive")
-	ErrTotal      = errors.New("upload: total must be a non-negative whole number of chunks")
+	ErrTotal      = errors.New("upload: total must not be negative")
 	ErrIndex      = errors.New("upload: chunk index out of range")
 	ErrBadLength  = errors.New("upload: chunk has the wrong length")
 	ErrDuplicate  = errors.New("upload: chunk already received")
@@ -25,22 +25,33 @@ type Assembler struct {
 	parts map[int][]byte
 }
 
-// New expects total bytes sent in chunks of chunkSize bytes.
+// New expects total bytes sent in chunks of chunkSize bytes. The last chunk may
+// be shorter; an empty upload is one empty chunk.
 func New(total int64, chunkSize int) (*Assembler, error) {
 	if chunkSize <= 0 {
 		return nil, ErrChunkSize
 	}
-	if total < 0 || total%int64(chunkSize) != 0 {
+	if total < 0 {
 		return nil, ErrTotal
 	}
+	count := total / int64(chunkSize)
+	if total%int64(chunkSize) != 0 || total == 0 {
+		count++
+	}
 	return &Assembler{
 		chunk: chunkSize,
 		total: total,
-		count: total / int64(chunkSize),
+		count: count,
 		parts: make(map[int][]byte),
 	}, nil
 }
 
+// wantLen is the length chunk idx must have: full size, except the last one
+// carries whatever is left. idx is already known to be in range.
+func (a *Assembler) wantLen(idx int) int {
+	return int(min(int64(a.chunk), a.total-int64(idx)*int64(a.chunk)))
+}
+
 // Add stores chunk number idx. The data is copied.
 func (a *Assembler) Add(idx int, data []byte) error {
 	a.mu.Lock()
@@ -48,7 +59,7 @@ func (a *Assembler) Add(idx int, data []byte) error {
 	if idx < 0 || int64(idx) >= a.count {
 		return ErrIndex
 	}
-	if len(data) != a.chunk {
+	if len(data) != a.wantLen(idx) {
 		return ErrBadLength
 	}
 	if _, ok := a.parts[idx]; ok {
@@ -58,6 +69,18 @@ func (a *Assembler) Add(idx int, data []byte) error {
 	return nil
 }
 
+// Received is the number of distinct bytes stored so far; a resent chunk is
+// refused, so it is never counted twice.
+func (a *Assembler) Received() int64 {
+	a.mu.Lock()
+	defer a.mu.Unlock()
+	var n int64
+	for _, p := range a.parts {
+		n += int64(len(p))
+	}
+	return n
+}
+
 // Complete reports whether every chunk has arrived.
 func (a *Assembler) Complete() bool {
 	a.mu.Lock()
PATCH_EOF
