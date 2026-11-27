#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/ledger.go b/ledger.go
index b48affc..58f252a 100644
--- a/ledger.go
+++ b/ledger.go
@@ -14,20 +14,37 @@ var (
 
 // Ledger moves money between accounts held in a Store.
 type Ledger struct {
-	store Store
+	store   Store
+	feeAcct string
+	feeBps  int64
 }
 
 // New returns a Ledger over s.
 func New(s Store) *Ledger { return &Ledger{store: s} }
 
+// WithFee returns a Ledger that charges feeBps basis points of every transfer
+// to the sender and credits it to feeAcct.
+func WithFee(s Store, feeAcct string, feeBps int64) *Ledger {
+	return &Ledger{store: s, feeAcct: feeAcct, feeBps: feeBps}
+}
+
 // Balance returns the balance of id in cents.
 func (l *Ledger) Balance(id string) (int64, error) { return l.store.Get(id) }
 
+// fee returns the fee for a transfer of cents, rounded up to a whole cent.
+func (l *Ledger) fee(cents int64) int64 {
+	if l.feeAcct == "" || l.feeBps <= 0 {
+		return 0
+	}
+	return (cents*l.feeBps + 9999) / 10000
+}
+
 // Transfer moves cents from one account to another.
 func (l *Ledger) Transfer(from, to string, cents int64) error {
-	if cents <= 0 || from == to {
+	if cents <= 0 || from == to || from == l.feeAcct || to == l.feeAcct {
 		return ErrInvalid
 	}
+	fee := l.fee(cents)
 	fb, err := l.store.Get(from)
 	if err != nil {
 		return fmt.Errorf("read %s: %w", from, err)
@@ -36,14 +53,20 @@ func (l *Ledger) Transfer(from, to string, cents int64) error {
 	if err != nil {
 		return fmt.Errorf("read %s: %w", to, err)
 	}
-	if fb < cents {
+	if fb < cents+fee {
 		return ErrInsufficient
 	}
-	if err := l.store.Put(from, fb-cents); err != nil {
+	if err := l.store.Put(from, fb-cents-fee); err != nil {
 		return fmt.Errorf("debit %s: %w", from, err)
 	}
 	if err := l.store.Put(to, tb+cents); err != nil {
 		return fmt.Errorf("credit %s: %w", to, err)
 	}
+	if fee > 0 {
+		fa, err := l.store.Get(l.feeAcct)
+		if err == nil {
+			l.store.Put(l.feeAcct, fa+fee)
+		}
+	}
 	return nil
 }
PATCH_EOF
