package domain

import "testing"

// provenance: derived
// verifies: Apply (deposit path)
func TestApply_DepositIncreasesBalanceAndEmitsEffect(t *testing.T) {
	state := NewState()
	next, effects := Apply(state, Event{ID: "e1", Type: EventDeposited, Amount: "10"})

	if next.Balance != "10.00000000" {
		t.Fatalf("balance = %q, want 10.00000000", next.Balance)
	}
	if next.Version != 1 {
		t.Fatalf("version = %d, want 1", next.Version)
	}
	if !next.Applied["e1"] {
		t.Fatal("e1 not marked applied")
	}
	if len(effects) != 1 {
		t.Fatalf("effects = %v, want exactly 1", effects)
	}
	dep, ok := effects[0].(EffectDeposited)
	if !ok || dep.Amount != "10" || dep.EventID != "e1" {
		t.Fatalf("effects[0] = %#v, want EffectDeposited{EventID:e1,Amount:10}", effects[0])
	}
}

// provenance: derived
// verifies: Apply (withdraw path, sufficient balance)
func TestApply_WithdrawWithSufficientBalanceSucceeds(t *testing.T) {
	state, _ := Apply(NewState(), Event{ID: "e1", Type: EventDeposited, Amount: "10"})
	next, effects := Apply(state, Event{ID: "e2", Type: EventWithdrawn, Amount: "4"})

	if next.Balance != "6.00000000" {
		t.Fatalf("balance = %q, want 6.00000000", next.Balance)
	}
	if _, ok := effects[0].(EffectWithdrawn); !ok {
		t.Fatalf("effects[0] = %#v, want EffectWithdrawn", effects[0])
	}
}

// provenance: derived
// verifies: Apply (withdraw path, insufficient balance) -- the ledger's
// balance is never allowed to go negative; this is the guard that protects
// units_conserved.
func TestApply_WithdrawExceedingBalanceIsRejectedNotApplied(t *testing.T) {
	state, _ := Apply(NewState(), Event{ID: "e1", Type: EventDeposited, Amount: "10"})
	next, effects := Apply(state, Event{ID: "e2", Type: EventWithdrawn, Amount: "11"})

	if next.Balance != "10.00000000" {
		t.Fatalf("balance = %q after rejected withdrawal, want unchanged 10.00000000", next.Balance)
	}
	if next.Version != state.Version {
		t.Fatalf("version = %d after rejected withdrawal, want unchanged %d", next.Version, state.Version)
	}
	rej, ok := effects[0].(EffectWithdrawalRejected)
	if !ok || rej.Reason != "insufficient balance" {
		t.Fatalf("effects[0] = %#v, want EffectWithdrawalRejected", effects[0])
	}
	// The rejected event ID must NOT be marked applied: a later legitimate
	// retry (e.g. after a deposit) must still be possible.
	if next.Applied["e2"] {
		t.Fatal("rejected withdrawal event ID was marked applied")
	}
}

// provenance: ratified
// verifies: duplicate_event_single_effect (this domain's own idempotency
// invariant -- see verification/ratified/invariants_test.go for the
// end-to-end, non-vacuity-evidenced version of this exact property)
func TestApply_DuplicateEventIDIsANoOp(t *testing.T) {
	state, _ := Apply(NewState(), Event{ID: "e1", Type: EventDeposited, Amount: "10"})
	again, effects := Apply(state, Event{ID: "e1", Type: EventDeposited, Amount: "10"})

	if again.Balance != state.Balance {
		t.Fatalf("balance changed on duplicate ID: %q -> %q", state.Balance, again.Balance)
	}
	if again.Version != state.Version {
		t.Fatalf("version changed on duplicate ID: %d -> %d", state.Version, again.Version)
	}
	if _, ok := effects[0].(EffectDuplicateIgnored); !ok {
		t.Fatalf("effects[0] = %#v, want EffectDuplicateIgnored", effects[0])
	}
}

// provenance: derived
// verifies: Apply total-function guarantee (malformed amount never panics,
// never partially mutates state)
func TestApply_MalformedAmountIsRejectedWithoutMutatingState(t *testing.T) {
	state := NewState()
	next, effects := Apply(state, Event{ID: "e1", Type: EventDeposited, Amount: "not-a-number"})
	if next.Balance != state.Balance || next.Version != state.Version {
		t.Fatalf("state mutated on malformed amount: %+v -> %+v", state, next)
	}
	if _, ok := effects[0].(EffectMalformedAmount); !ok {
		t.Fatalf("effects[0] = %#v, want EffectMalformedAmount", effects[0])
	}
}

// provenance: derived
// verifies: Apply total-function guarantee (unknown event type never panics)
func TestApply_UnknownEventTypeIsRejectedWithoutMutatingState(t *testing.T) {
	state := NewState()
	next, effects := Apply(state, Event{ID: "e1", Type: "not-a-real-type", Amount: "1"})
	if next.Balance != state.Balance {
		t.Fatalf("state mutated on unknown event type: %+v -> %+v", state, next)
	}
	if _, ok := effects[0].(EffectUnknownEventType); !ok {
		t.Fatalf("effects[0] = %#v, want EffectUnknownEventType", effects[0])
	}
}

// provenance: derived
// verifies: State.Clone deep-copies Applied (a shared map would let two
// States alias each other's idempotency bookkeeping)
func TestStateClone_AppliedMapIsIndependent(t *testing.T) {
	s1 := NewState()
	s1.Applied["e1"] = true
	s2 := s1.Clone()
	s2.Applied["e2"] = true

	if s1.Applied["e2"] {
		t.Fatal("mutating the clone's Applied map mutated the original")
	}
}

// provenance: derived
// verifies: ConservationHolds correctly distinguishes a real violation from
// every legitimate transition -- exercised directly (not only through
// Apply) so the counter that wraps it (internal/app) is proven to detect a
// genuine mismatch, not just to always return true.
func TestConservationHolds(t *testing.T) {
	before := NewState()
	before.Balance = "10.00000000"
	event := Event{ID: "e1", Type: EventDeposited, Amount: "5"}

	correct := before.Clone()
	correct.Balance = "15.00000000"
	correct.Version = before.Version + 1
	if !ConservationHolds(before, event, correct) {
		t.Fatal("ConservationHolds rejected a correct deposit transition")
	}

	violating := before.Clone()
	violating.Balance = "16.00000000" // wrong: should be 15
	violating.Version = before.Version + 1
	if ConservationHolds(before, event, violating) {
		t.Fatal("ConservationHolds accepted a balance that does not match the deposit")
	}
}

// provenance: derived
// verifies: State.AppliedIDs returns a deterministic, sorted view
func TestState_AppliedIDsIsSorted(t *testing.T) {
	s := NewState()
	s.Applied["zebra"] = true
	s.Applied["apple"] = true
	s.Applied["mango"] = true
	got := s.AppliedIDs()
	want := []string{"apple", "mango", "zebra"}
	if len(got) != len(want) {
		t.Fatalf("AppliedIDs() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("AppliedIDs() = %v, want %v", got, want)
		}
	}
}
