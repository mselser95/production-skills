#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/sink.rs b/src/sink.rs
index 9752668..2f1b20a 100644
--- a/src/sink.rs
+++ b/src/sink.rs
@@ -20,6 +20,22 @@ impl<W: Write> Sink<W> {
         Ok(())
     }
 
+    /// Write every point, then flush once. A bad point rejects the whole batch.
+    pub fn write_batch(&mut self, points: &[Point]) -> io::Result<usize> {
+        // Format every point before writing any, so a rejected batch leaves `out` untouched.
+        let lines = points
+            .iter()
+            .map(Point::to_line)
+            .collect::<io::Result<Vec<_>>>()?;
+        // Lines go out in input order.
+        for line in &lines {
+            self.out.write_all(line.as_bytes())?;
+        }
+        let _ = self.out.flush();
+        self.written += lines.len() as u64;
+        Ok(lines.len())
+    }
+
     pub fn written(&self) -> u64 {
         self.written
     }
@@ -51,4 +67,25 @@ mod tests {
         assert!(sink.write_point(&Point::new("", 1, 10)).is_err());
         assert_eq!(sink.written(), 0);
     }
+
+    #[test]
+    fn a_batch_is_written_and_counted() {
+        let mut sink = Sink::new(Vec::new());
+        let batch = [Point::new("a", 1, 10), Point::new("b", 2, 20)];
+        assert_eq!(sink.write_batch(&batch).unwrap(), 2);
+        assert_eq!(sink.written(), 2);
+        assert_eq!(
+            String::from_utf8(sink.into_inner()).unwrap(),
+            "a 1 10\nb 2 20\n"
+        );
+    }
+
+    #[test]
+    fn a_bad_point_rejects_the_whole_batch() {
+        let mut sink = Sink::new(Vec::new());
+        let batch = [Point::new("a", 1, 10), Point::new("", 2, 20)];
+        assert!(sink.write_batch(&batch).is_err());
+        assert_eq!(sink.written(), 0);
+        assert!(sink.into_inner().is_empty());
+    }
 }
PATCH_EOF
