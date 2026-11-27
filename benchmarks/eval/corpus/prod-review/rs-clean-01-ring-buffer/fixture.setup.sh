#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/ring.rs b/src/ring.rs
index 4146131..319361d 100644
--- a/src/ring.rs
+++ b/src/ring.rs
@@ -51,6 +51,41 @@ impl<T> Ring<T> {
         self.slots[self.head].as_ref()
     }
 
+    /// Append `item`. When the ring is full the oldest item is evicted and returned.
+    pub fn push(&mut self, item: T) -> Option<T> {
+        let cap = self.slots.len();
+        if self.len == cap {
+            // Full: the slot at `head` is the oldest item and also the next free one.
+            let evicted = self.slots[self.head].replace(item);
+            self.head = (self.head + 1) % cap;
+            // Monitors only compare this counter for change, so wrapping is fine.
+            self.dropped = self.dropped.wrapping_add(1);
+            return evicted;
+        }
+        self.slots[(self.head + self.len) % cap] = Some(item);
+        self.len += 1;
+        None
+    }
+
+    /// Remove and return the oldest item.
+    pub fn pop_front(&mut self) -> Option<T> {
+        if self.len == 0 {
+            return None;
+        }
+        let item = self.slots[self.head].take();
+        self.head = (self.head + 1) % self.slots.len();
+        self.len -= 1;
+        item
+    }
+
+    /// The `i`-th oldest item, if there is one.
+    pub fn get(&self, i: usize) -> Option<&T> {
+        if i >= self.len {
+            return None;
+        }
+        self.slots[(self.head + i) % self.slots.len()].as_ref()
+    }
+
     pub fn capacity(&self) -> usize {
         self.slots.len()
     }
@@ -89,4 +124,39 @@ mod tests {
             Err(RingError::TooLarge)
         ));
     }
+
+    #[test]
+    fn push_evicts_the_oldest_when_full() {
+        let mut r = Ring::new(3).unwrap();
+        assert_eq!(r.push(1), None);
+        assert_eq!(r.push(2), None);
+        assert_eq!(r.push(3), None);
+        assert_eq!(r.push(4), Some(1));
+        assert_eq!((r.len(), r.dropped()), (3, 1));
+        assert_eq!((r.get(0), r.get(2), r.get(3)), (Some(&2), Some(&4), None));
+        assert_eq!(r.peek_oldest(), Some(&2));
+    }
+
+    #[test]
+    fn pop_front_returns_items_oldest_first() {
+        let mut r = Ring::new(2).unwrap();
+        r.push('a');
+        r.push('b');
+        r.push('c');
+        assert_eq!(r.pop_front(), Some('b'));
+        assert_eq!(r.pop_front(), Some('c'));
+        assert_eq!(r.pop_front(), None);
+        assert!(r.is_empty());
+    }
+
+    #[test]
+    fn order_survives_many_wraps() {
+        let mut r = Ring::new(7).unwrap();
+        for i in 0..1000u32 {
+            r.push(i);
+        }
+        let kept: Vec<u32> = (0..r.len()).filter_map(|i| r.get(i).copied()).collect();
+        assert_eq!(kept, (993..1000).collect::<Vec<_>>());
+        assert_eq!(r.dropped(), 993);
+    }
 }
PATCH_EOF
