// NON-VACUITY EVIDENCE (verified empirically 2026-08-17, each mutation
// applied to production code, test observed RED, mutation reverted):
//
//	units_conserved                <- internal/domain/ledger.go, Apply's
//	                                   EventDeposited branch: changed
//	                                   `AddAmounts(state.Balance,
//	                                   event.Amount)` to
//	                                   `AddAmounts(state.Balance,
//	                                   state.Balance)` (doubles balance
//	                                   instead of adding the deposit)
//	                                   => RED: withdraw w1 (0.3) against a
//	                                   corrupted balance was rejected as
//	                                   insufficient
//	                                   ("effects[0] = EffectWithdrawalRejected
//	                                   ..., want EffectWithdrawn")
//	duplicate_event_single_effect  <- internal/domain/ledger.go, Apply's
//	                                   idempotency guard: changed
//	                                   `if state.Applied[event.ID] {` to
//	                                   `if false {` (duplicate IDs re-applied)
//	                                   => RED: "balance changed on duplicate
//	                                   ID" / final balance double-counted
//
// A ratified invariant that has never been observed red is a decoration.
// Rerun these mutations when either cited line moves.
//
// Package ratified holds this service's human-ratified invariants as
// executable tests. This directory is part of the trusted set: changes land
// only through the human ratification flow (see .prod/ratify-queue/ for the
// provenance packages behind each invariant). These tests carry the T0
// rule: a nondeterministic failure here is an INCIDENT, never a quarantine
// (tier-policy.yaml: invariant_flake_rule).
package ratified

import (
	"math/big"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: ratified
// verifies: units_conserved (ratified 2026-08-17)
//
// For any sequence of admitted deposits and withdrawals: initial balance +
// sum(deposits) - sum(withdrawals) == final balance. Tracked independently
// via math/big, never by trusting domain's own arithmetic to check itself.
func TestInvariant_UnitsConserved(t *testing.T) {
	state := domain.NewState()
	expected := new(big.Int)

	deposit := func(id string, units int64) {
		amt := domain.FormatAmount(big.NewInt(units))
		next, effects := domain.Apply(state, domain.Event{ID: id, Type: domain.EventDeposited, Amount: amt})
		state = next
		if _, ok := effects[0].(domain.EffectDeposited); !ok {
			t.Fatalf("deposit %s: effects[0] = %#v, want EffectDeposited", id, effects[0])
		}
		expected.Add(expected, big.NewInt(units))
	}
	withdraw := func(id string, units int64) {
		amt := domain.FormatAmount(big.NewInt(units))
		next, effects := domain.Apply(state, domain.Event{ID: id, Type: domain.EventWithdrawn, Amount: amt})
		state = next
		if _, ok := effects[0].(domain.EffectWithdrawn); !ok {
			t.Fatalf("withdraw %s: effects[0] = %#v, want EffectWithdrawn", id, effects[0])
		}
		expected.Sub(expected, big.NewInt(units))
	}

	deposit("d1", 1_000_000_00) // 1.00000000
	deposit("d2", 250_000_00)   // 0.25000000
	withdraw("w1", 300_000_00)  // 0.30000000
	deposit("d3", 5)
	withdraw("w2", 2)

	want := domain.FormatAmount(expected)
	if state.Balance != want {
		t.Fatalf("final balance = %q, want %q (independently tracked: deposits minus withdrawals)", state.Balance, want)
	}

	// A rejected withdrawal (exceeds balance) must NOT perturb conservation:
	// the independent tracker is not updated, and neither is the real
	// balance.
	before := state.Balance
	rejectedState, effects := domain.Apply(state, domain.Event{ID: "w-huge", Type: domain.EventWithdrawn, Amount: "99999999"})
	if _, ok := effects[0].(domain.EffectWithdrawalRejected); !ok {
		t.Fatalf("effects[0] = %#v, want EffectWithdrawalRejected", effects[0])
	}
	if rejectedState.Balance != before {
		t.Fatalf("balance changed on a rejected withdrawal: %q -> %q", before, rejectedState.Balance)
	}
}

// provenance: ratified
// verifies: duplicate_event_single_effect (ratified 2026-08-17)
//
// Applying the SAME event (same ID) twice has the ledger's economic effect
// exactly once: the second application is a strict, provable no-op.
func TestInvariant_DuplicateEventAppliedOnce(t *testing.T) {
	state := domain.NewState()
	event := domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"}

	once, effectsOnce := domain.Apply(state, event)
	if once.Balance != "10.00000000" {
		t.Fatalf("balance after first application = %q, want 10.00000000", once.Balance)
	}
	if _, ok := effectsOnce[0].(domain.EffectDeposited); !ok {
		t.Fatalf("first application effects[0] = %#v, want EffectDeposited", effectsOnce[0])
	}

	twice, effectsTwice := domain.Apply(once, event)
	if twice.Balance != once.Balance {
		t.Fatalf("balance after re-applying the SAME event ID: %q -> %q, want unchanged", once.Balance, twice.Balance)
	}
	if twice.Version != once.Version {
		t.Fatalf("version after re-applying the SAME event ID: %d -> %d, want unchanged", once.Version, twice.Version)
	}
	if _, ok := effectsTwice[0].(domain.EffectDuplicateIgnored); !ok {
		t.Fatalf("second application effects[0] = %#v, want EffectDuplicateIgnored", effectsTwice[0])
	}

	// Applying a DIFFERENT event ID afterward still works normally --
	// idempotency is scoped to the ID, not a global "ledger is frozen"
	// state.
	after, effectsAfter := domain.Apply(twice, domain.Event{ID: "e2", Type: domain.EventDeposited, Amount: "5"})
	if after.Balance != "15.00000000" {
		t.Fatalf("balance after a fresh event ID = %q, want 15.00000000", after.Balance)
	}
	if _, ok := effectsAfter[0].(domain.EffectDeposited); !ok {
		t.Fatalf("effects[0] = %#v, want EffectDeposited", effectsAfter[0])
	}
}
