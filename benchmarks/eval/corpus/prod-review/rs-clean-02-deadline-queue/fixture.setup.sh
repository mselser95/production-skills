#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/queue.rs b/src/queue.rs
index 6be7f5d..50d4b91 100644
--- a/src/queue.rs
+++ b/src/queue.rs
@@ -44,14 +44,30 @@ impl<T> DeadlineQueue<T> {
             .checked_add(ttl_ms)
             .ok_or(QueueError::DeadlineOverflow)?;
         let seq = self.next_seq.fetch_add(1, Ordering::Relaxed);
-        self.heap.lock().unwrap().push(Entry {
-            deadline_ms,
-            seq,
-            item,
-        });
+        {
+            let mut heap = self.heap.lock().unwrap();
+            heap.push(Entry {
+                deadline_ms,
+                seq,
+                item,
+            });
+        }
+        // The wake-up is only a hint for an idle consumer. A dropped receiver
+        // means nobody is waiting, and the item is queued either way.
+        let _ = self.wake.send(());
         Ok(deadline_ms)
     }
 
+    /// Take up to `max` items whose deadline is at or before `now_ms`, earliest first.
+    pub fn pop_due(&self, now_ms: u64, max: usize) -> Vec<T> {
+        let mut heap = self.heap.lock().unwrap();
+        let mut due = Vec::new();
+        while due.len() < max && heap.peek().is_some_and(|e| e.deadline_ms <= now_ms) {
+            due.extend(heap.pop().map(|e| e.item));
+        }
+        due
+    }
+
     /// Remove the item with the earliest deadline, due or not.
     pub fn pop_next(&self) -> Option<T> {
         self.heap.lock().unwrap().pop().map(|e| e.item)
@@ -103,4 +119,44 @@ mod tests {
         assert_eq!(q.push(1, u64::MAX, 1), Err(QueueError::DeadlineOverflow));
         assert!(q.is_empty());
     }
+
+    #[test]
+    fn pop_due_returns_only_what_is_due() {
+        let (tx, _rx) = mpsc::channel();
+        let q = DeadlineQueue::new(tx);
+        q.push("late", 0, 50).unwrap();
+        q.push("b", 0, 10).unwrap();
+        q.push("a", 0, 10).unwrap();
+        assert_eq!(q.pop_due(9, 10), Vec::<&str>::new());
+        assert_eq!(q.pop_due(10, 10), vec!["b", "a"]);
+        assert_eq!(q.len(), 1);
+    }
+
+    #[test]
+    fn pop_due_honours_the_limit() {
+        let (tx, _rx) = mpsc::channel();
+        let q = DeadlineQueue::new(tx);
+        for i in 0..5 {
+            q.push(i, 0, 1).unwrap();
+        }
+        assert_eq!(q.pop_due(1, 2), vec![0, 1]);
+        assert_eq!(q.len(), 3);
+    }
+
+    #[test]
+    fn push_still_queues_after_the_receiver_is_gone() {
+        let (tx, rx) = mpsc::channel();
+        drop(rx);
+        let q = DeadlineQueue::new(tx);
+        assert_eq!(q.push(1, 0, 5), Ok(5));
+        assert_eq!(q.len(), 1);
+    }
+
+    #[test]
+    fn push_wakes_the_consumer() {
+        let (tx, rx) = mpsc::channel();
+        let q = DeadlineQueue::new(tx);
+        q.push(1, 0, 5).unwrap();
+        assert!(rx.try_recv().is_ok());
+    }
 }
PATCH_EOF
