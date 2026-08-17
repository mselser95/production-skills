package app

import (
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: derived
// verifies: units_conserved (invariant counter must stay 0 under real
// operation, matching verification/ratified's own non-vacuity discipline)
func TestConservationViolations_StaysZeroUnderNormalOperation(t *testing.T) {
	l, _, _ := newTestLedger()
	for i, amt := range []string{"5", "3", "1"} {
		id := "e" + string(rune('0'+i))
		if _, err := l.Deposit(t.Context(), id, amt); err != nil {
			t.Fatalf("Deposit: %v", err)
		}
	}
	if _, err := l.Withdraw(t.Context(), "w1", "2"); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if got := l.ConservationViolations(); got != 0 {
		t.Fatalf("ConservationViolations=%d after only legitimate commands, want 0", got)
	}
}

// provenance: derived
// verifies: units_conserved (proves the counter is wired to something that
// can actually fire -- a deliberately violating (before, event, after)
// triple that domain.Apply's own real control flow could never produce)
func TestConservationViolations_IncrementsOnDeliberateViolation(t *testing.T) {
	l, _, _ := newTestLedger()
	before := domain.NewState()
	before.Balance = "10.00000000"
	event := domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "5"}
	after := before.Clone()
	after.Balance = "999.00000000" // wrong: a real Apply would produce 15
	after.Version = before.Version + 1

	l.CheckInvariantsForTest(before, event, after)
	if got := l.ConservationViolations(); got != 1 {
		t.Fatalf("ConservationViolations=%d after one deliberately violating call, want 1", got)
	}
	if l.LastInvariantViolationAt().IsZero() {
		t.Fatal("LastInvariantViolationAt() is zero after a recorded violation")
	}
}

// provenance: derived
// verifies: duplicate_event_single_effect (invariant counter must stay 0
// under real operation, including a genuine duplicate submission -- since
// domain.Apply's own idempotency guard is what keeps it at 0)
func TestDuplicateEffectViolations_StaysZeroUnderNormalOperation(t *testing.T) {
	l, _, _ := newTestLedger()
	if _, err := l.Deposit(t.Context(), "e1", "10"); err != nil {
		t.Fatalf("first Deposit: %v", err)
	}
	if _, err := l.Deposit(t.Context(), "e1", "10"); err != nil {
		t.Fatalf("duplicate Deposit: %v", err)
	}
	if got := l.DuplicateEffectViolations(); got != 0 {
		t.Fatalf("DuplicateEffectViolations=%d after a real (correctly no-op'd) duplicate, want 0", got)
	}
}

// provenance: derived
// verifies: duplicate_event_single_effect (proves the counter is wired: a
// deliberately violating triple where an already-applied ID's balance
// nonetheless differs from before -- domain.Apply's real duplicate branch
// can never produce this, since it returns `state` completely unchanged)
func TestDuplicateEffectViolations_IncrementsOnDeliberateViolation(t *testing.T) {
	l, _, _ := newTestLedger()
	before := domain.NewState()
	before.Balance = "10.00000000"
	before.Applied["e1"] = true
	event := domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "5"}
	after := before.Clone()
	after.Balance = "15.00000000" // wrong: a duplicate ID must be a strict no-op

	l.CheckInvariantsForTest(before, event, after)
	if got := l.DuplicateEffectViolations(); got != 1 {
		t.Fatalf("DuplicateEffectViolations=%d after one deliberately violating call, want 1", got)
	}
}

// provenance: derived
// verifies: LastInvariantViolationAt zero value contract (readiness gate
// depends on IsZero meaning "never violated")
func TestLastInvariantViolationAt_ZeroBeforeAnyViolation(t *testing.T) {
	l, _, _ := newTestLedger()
	if !l.LastInvariantViolationAt().IsZero() {
		t.Fatal("LastInvariantViolationAt() is non-zero before any violation was recorded")
	}
}
