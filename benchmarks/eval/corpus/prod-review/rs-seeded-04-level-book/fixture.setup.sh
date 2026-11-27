#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/book.rs b/src/book.rs
index 95c647f..8e6cfef 100644
--- a/src/book.rs
+++ b/src/book.rs
@@ -48,6 +48,15 @@ impl OrderBook {
         self.asks.iter().next().map(|(p, q)| (*p, *q))
     }
 
+    /// True when `other` shows the same best `depth` levels on both sides.
+    /// Levels are compared best first.
+    /// Used to check a replica that was fed the same update stream.
+    pub fn same_top(&self, other: &OrderBook, depth: usize) -> bool {
+        let same = |a: Vec<(u64, u64)>, b: Vec<(u64, u64)>| a.iter().zip(&b).all(|(x, y)| x == y);
+        same(self.top_bids(depth), other.top_bids(depth))
+            && same(self.top_asks(depth), other.top_asks(depth))
+    }
+
     /// Up to `n` bid levels, best (highest) first.
     pub fn top_bids(&self, n: usize) -> Vec<(u64, u64)> {
         self.bids
@@ -100,4 +109,29 @@ mod tests {
         assert_eq!(b.top_bids(2), vec![(102, 2), (101, 3)]);
         assert_eq!(b.top_asks(2), vec![(110, 1), (111, 3)]);
     }
+
+    #[test]
+    fn identical_books_have_the_same_top() {
+        let mut a = OrderBook::new();
+        let mut b = OrderBook::new();
+        for u in [upd(Side::Bid, 100, 5), upd(Side::Ask, 103, 7)] {
+            a.apply(&u);
+            b.apply(&u);
+        }
+        assert!(a.same_top(&b, 5));
+        assert!(OrderBook::new().same_top(&OrderBook::new(), 5));
+    }
+
+    #[test]
+    fn a_different_quantity_or_price_breaks_the_match() {
+        let mut a = OrderBook::new();
+        let mut b = a.clone();
+        a.apply(&upd(Side::Bid, 100, 5));
+        b.apply(&upd(Side::Bid, 100, 6));
+        assert!(!a.same_top(&b, 1));
+        b.apply(&upd(Side::Bid, 100, 5));
+        b.apply(&upd(Side::Ask, 105, 1));
+        a.apply(&upd(Side::Ask, 106, 1));
+        assert!(!a.same_top(&b, 1));
+    }
 }
PATCH_EOF
