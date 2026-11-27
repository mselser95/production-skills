#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/catalog.go b/catalog.go
index 86fe812..4d2784d 100644
--- a/catalog.go
+++ b/catalog.go
@@ -48,3 +48,25 @@ func (c *Catalog) List(offset, limit int) []Item {
 	}
 	return append([]Item(nil), c.items[offset:end]...)
 }
+
+// After returns up to limit items that follow the item whose ID is cursor, and
+// the cursor for the next page ("" when there is none). An empty cursor starts
+// at the first item.
+func (c *Catalog) After(cursor string, limit int) ([]Item, string) {
+	if limit <= 0 {
+		limit = DefaultLimit
+	}
+	start := 0
+	if cursor != "" {
+		start = sort.Search(len(c.items), func(i int) bool { return c.items[i].ID >= cursor })
+	}
+	end := start + limit
+	if end > len(c.items) {
+		end = len(c.items)
+	}
+	page := append([]Item(nil), c.items[start:end]...)
+	if end == len(c.items) || len(page) == 0 {
+		return page, ""
+	}
+	return page, page[len(page)-1].ID
+}
PATCH_EOF
