#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/cache.go b/cache.go
index 7f0a485..190b527 100644
--- a/cache.go
+++ b/cache.go
@@ -32,9 +32,19 @@ func New(ttl time.Duration, now func() time.Time) *Cache {
 
 // Put stores val under key for the cache's default ttl.
 func (c *Cache) Put(key string, val []byte) {
+	c.put(key, val, c.ttl)
+}
+
+// PutFor stores val under key for ttlMillis milliseconds, for responses that
+// should be remembered for less (or longer) than the default.
+func (c *Cache) PutFor(key string, val []byte, ttlMillis int64) {
+	c.put(key, val, time.Duration(ttlMillis)*time.Second)
+}
+
+func (c *Cache) put(key string, val []byte, ttl time.Duration) {
 	c.mu.Lock()
 	defer c.mu.Unlock()
-	c.entries[key] = entry{val: val, expires: c.now().Add(c.ttl)}
+	c.entries[key] = entry{val: val, expires: c.now().Add(ttl)}
 }
 
 // Get returns the stored response for key, or false if there is none or it has
@@ -59,3 +69,19 @@ func (c *Cache) Len() int {
 	defer c.mu.Unlock()
 	return len(c.entries)
 }
+
+// Sweep drops every expired entry and returns how many it removed. Run it from
+// a ticker to bound memory for keys that are never read again.
+func (c *Cache) Sweep() int {
+	c.mu.Lock()
+	defer c.mu.Unlock()
+	now := c.now()
+	n := 0
+	for k, e := range c.entries {
+		if !now.Before(e.expires) {
+			delete(c.entries, k)
+			n++
+		}
+	}
+	return n
+}
PATCH_EOF
