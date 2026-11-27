#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/error.rs b/src/error.rs
index 5b13f90..856c554 100644
--- a/src/error.rs
+++ b/src/error.rs
@@ -4,12 +4,14 @@ use std::fmt;
 #[non_exhaustive]
 pub enum StoreError {
     EmptyKey,
+    Full { live: usize },
 }
 
 impl fmt::Display for StoreError {
     fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
         match self {
             StoreError::EmptyKey => write!(f, "key must not be empty"),
+            StoreError::Full { live } => write!(f, "store is full ({live} live entries)"),
         }
     }
 }
diff --git a/src/store.rs b/src/store.rs
index 4b7d4f7..9e5f1d5 100644
--- a/src/store.rs
+++ b/src/store.rs
@@ -41,6 +41,35 @@ impl Store {
             .map(|e| e.value.clone())
     }
 
+    /// Like `put`, but refuses a new key once `max` entries are held.
+    pub fn put_bounded(
+        &self,
+        key: &str,
+        value: &str,
+        ttl_ms: u64,
+        now_ms: u64,
+        max: usize,
+    ) -> Result<(), StoreError> {
+        if key.is_empty() {
+            return Err(StoreError::EmptyKey);
+        }
+        let mut map = self.inner.lock().unwrap();
+        // Expired entries do not count against the bound, so purge them first.
+        map.retain(|_, e| e.expires_at_ms > now_ms);
+        // An existing key is an update, not growth, so it is always allowed.
+        if map.len() >= max && !map.contains_key(key) {
+            return Err(StoreError::Full { live: self.len() });
+        }
+        map.insert(
+            key.to_string(),
+            Entry {
+                value: value.to_string(),
+                expires_at_ms: now_ms.saturating_add(ttl_ms),
+            },
+        );
+        Ok(())
+    }
+
     /// Number of stored entries, expired ones included until they are purged.
     pub fn len(&self) -> usize {
         self.inner.lock().unwrap().len()
@@ -76,4 +105,29 @@ mod tests {
         assert_eq!(s.put("", "1", 100, 0), Err(StoreError::EmptyKey));
         assert!(s.is_empty());
     }
+
+    #[test]
+    fn bounded_put_accepts_new_keys_below_the_bound() {
+        let s = Store::new();
+        s.put_bounded("a", "1", 100, 0, 2).unwrap();
+        s.put_bounded("b", "2", 100, 0, 2).unwrap();
+        assert_eq!(s.len(), 2);
+    }
+
+    #[test]
+    fn bounded_put_overwrites_an_existing_key_at_the_bound() {
+        let s = Store::new();
+        s.put_bounded("a", "1", 100, 0, 1).unwrap();
+        s.put_bounded("a", "2", 100, 10, 1).unwrap();
+        assert_eq!(s.get("a", 20).as_deref(), Some("2"));
+    }
+
+    #[test]
+    fn bounded_put_purges_expired_entries_first() {
+        let s = Store::new();
+        s.put_bounded("a", "1", 10, 0, 1).unwrap();
+        s.put_bounded("b", "2", 10, 20, 1).unwrap();
+        assert_eq!(s.len(), 1);
+        assert_eq!(s.get("b", 21).as_deref(), Some("2"));
+    }
 }
PATCH_EOF
