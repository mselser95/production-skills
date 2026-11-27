#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/meter.go b/meter.go
index ece8879..f7e5358 100644
--- a/meter.go
+++ b/meter.go
@@ -34,13 +34,41 @@ func (m *Meter) Charge(tenant string, n int64) error {
 	}
 	m.mu.Lock()
 	defer m.mu.Unlock()
+	now := m.now()
+	used := m.prune(tenant, now)
+	// Compared as n > limit-used, not used+n > limit: used <= limit, so the
+	// subtraction cannot overflow, while the sum could for a huge n.
+	if n > m.limit-used {
+		return ErrLimit
+	}
+	m.used[tenant] = append(m.used[tenant], entry{at: now, n: n})
+	return nil
+}
+
+// Remaining returns the units tenant can still be charged right now.
+func (m *Meter) Remaining(tenant string) int64 {
+	m.mu.Lock()
+	defer m.mu.Unlock()
+	return m.limit - m.prune(tenant, m.now())
+}
+
+// prune drops tenant's entries older than the window and returns the units
+// left. The window is closed on purpose: an entry exactly one window old still
+// counts, so units never come back a tick early. Kept entries sum to <= limit.
+func (m *Meter) prune(tenant string, now time.Time) int64 {
 	var used int64
+	kept := m.used[tenant][:0]
 	for _, e := range m.used[tenant] {
+		if now.Sub(e.at) > m.window {
+			continue
+		}
+		kept = append(kept, e)
 		used += e.n
 	}
-	if used+n > m.limit {
-		return ErrLimit
+	if len(kept) == 0 {
+		delete(m.used, tenant)
+	} else {
+		m.used[tenant] = kept
 	}
-	m.used[tenant] = append(m.used[tenant], entry{at: m.now(), n: n})
-	return nil
+	return used
 }
PATCH_EOF
