#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/ops.go b/ops.go
new file mode 100644
index 0000000..a7c04c1
--- /dev/null
+++ b/ops.go
@@ -0,0 +1,46 @@
+package lease
+
+import "time"
+
+// A lease is live only while now is strictly before its expiry: at
+// expiry == now it is already expired. Acquire, Renew and Release all decide
+// through live, so they agree on that boundary, and all read the injected clock.
+func (e entry) live(now time.Time) bool { return now.Before(e.expires) }
+
+// Acquire takes the lease on name for owner and returns its expiry. A live
+// lease of another owner is refused; the owner's own live lease is extended.
+func (k *Keeper) Acquire(name, owner string) (time.Time, error) {
+	k.mu.Lock()
+	defer k.mu.Unlock()
+	now := k.clock.Now()
+	if e, ok := k.leases[name]; ok && e.live(now) && e.owner != owner {
+		return time.Time{}, ErrHeld
+	}
+	exp := now.Add(k.ttl)
+	k.leases[name] = entry{owner: owner, expires: exp}
+	return exp, nil
+}
+
+func (k *Keeper) Renew(name, owner string) (time.Time, error) {
+	k.mu.Lock()
+	defer k.mu.Unlock()
+	now := k.clock.Now()
+	if e, ok := k.leases[name]; !ok || !e.live(now) || e.owner != owner {
+		return time.Time{}, ErrNotHeld
+	}
+	exp := now.Add(k.ttl)
+	k.leases[name] = entry{owner: owner, expires: exp}
+	return exp, nil
+}
+
+// Release drops owner's live lease on name; an expired one is already gone.
+func (k *Keeper) Release(name, owner string) error {
+	k.mu.Lock()
+	defer k.mu.Unlock()
+	e, ok := k.leases[name]
+	if !ok || !e.live(k.clock.Now()) || e.owner != owner {
+		return ErrNotHeld
+	}
+	delete(k.leases, name)
+	return nil
+}
PATCH_EOF
