#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/importer.go b/importer.go
index 90c5bbb..16c307f 100644
--- a/importer.go
+++ b/importer.go
@@ -3,11 +3,14 @@ package bulkimport
 
 import (
 	"bufio"
+	"bytes"
 	"context"
-	"fmt"
 	"io"
 )
 
+// maxRowBytes is the longest accepted row.
+const maxRowBytes = 1 << 20
+
 // Store persists one record. Put may fail; the record is then not stored.
 type Store interface {
 	Put(ctx context.Context, rec Record) error
@@ -20,24 +23,28 @@ type Result struct {
 }
 
 // Import reads JSONL records from r, validates each one and stores the valid
-// ones. Invalid rows are counted in Rejected and skipped. A store failure
-// stops the import and is returned with its row number.
+// ones. Invalid rows are counted in Rejected and skipped. Blank lines are
+// ignored. A row that cannot be stored does not stop the import: the rows
+// after it are still read and stored, so one bad row costs one row.
 func Import(ctx context.Context, r io.Reader, s Store) (Result, error) {
 	var res Result
 	sc := bufio.NewScanner(r)
-	row := 0
+	// Rows may be longer than the scanner's 64 KiB default.
+	sc.Buffer(make([]byte, 0, 64*1024), maxRowBytes)
 	for sc.Scan() {
-		row++
 		if err := ctx.Err(); err != nil {
 			return res, err
 		}
+		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
+			continue
+		}
 		rec, err := Parse(sc.Bytes())
 		if err != nil {
 			res.Rejected++
 			continue
 		}
 		if err := s.Put(ctx, rec); err != nil {
-			return res, fmt.Errorf("row %d: %w", row, err)
+			continue
 		}
 		res.Stored++
 	}
PATCH_EOF
