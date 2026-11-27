#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/src/frame.rs b/src/frame.rs
index c4e0894..119a649 100644
--- a/src/frame.rs
+++ b/src/frame.rs
@@ -30,6 +30,22 @@ pub fn checksum(payload: &[u8]) -> u8 {
     payload.iter().fold(0u8, |acc, b| acc.wrapping_add(*b))
 }
 
+/// Encode `payload` as one frame.
+pub fn encode(payload: &[u8]) -> Vec<u8> {
+    let len = payload.len() as u16;
+    let mut out = Vec::with_capacity(HEADER_LEN + payload.len() + 1);
+    // Header, then the payload, then the checksum over the payload.
+    out.extend_from_slice(&len.to_be_bytes());
+    out.extend_from_slice(payload);
+    out.push(checksum(payload));
+    out
+}
+
+/// Encode several payloads back to back.
+pub fn encode_all(payloads: &[&[u8]]) -> Vec<u8> {
+    payloads.iter().flat_map(|p| encode(p)).collect()
+}
+
 /// Decode one frame from the front of `buf`: the payload and the bytes consumed.
 pub fn decode(buf: &[u8]) -> Result<(&[u8], usize), FrameError> {
     if buf.len() < HEADER_LEN {
@@ -76,4 +92,23 @@ mod tests {
             })
         );
     }
+
+    #[test]
+    fn encode_matches_the_wire_format() {
+        assert_eq!(encode(&[1, 2, 3]), vec![0, 3, 1, 2, 3, 6]);
+        assert_eq!(encode(&[]), vec![0, 0, 0]);
+    }
+
+    #[test]
+    fn encode_then_decode_round_trips() {
+        let payload: Vec<u8> = (0..300u32).map(|i| (i % 251) as u8).collect();
+        let wire = encode(&payload);
+        assert_eq!(decode(&wire), Ok((&payload[..], wire.len())));
+    }
+
+    #[test]
+    fn encode_all_concatenates_frames() {
+        let wire = encode_all(&[&[7], &[1, 1]]);
+        assert_eq!(wire, vec![0, 1, 7, 7, 0, 2, 1, 1, 2]);
+    }
 }
diff --git a/src/lib.rs b/src/lib.rs
index f4cc7f2..29065a4 100644
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -5,5 +5,5 @@
 mod frame;
 mod stream;
 
-pub use frame::{checksum, decode, FrameError, HEADER_LEN};
+pub use frame::{checksum, decode, encode, encode_all, FrameError, HEADER_LEN};
 pub use stream::decode_all;
PATCH_EOF
