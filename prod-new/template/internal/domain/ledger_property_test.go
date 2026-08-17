package domain

import (
	"fmt"
	"math/big"
	"math/rand"
	"testing"
)

// provenance: derived
// verifies: units_conserved (property form of the ratified invariant --
// verification/ratified/invariants_test.go carries the ratified,
// non-vacuity-evidenced instance; this property test is the broader
// generator-driven sweep that gives that invariant statistical confidence
// across a much larger state space than a handful of fixed examples could)
//
// For ANY sequence of deposit/withdraw events replayed through Apply in
// order: initial balance + sum(admitted deposits) - sum(admitted
// withdrawals) == final balance, tracked independently in this test via
// math/big (never by trusting the ledger's own arithmetic to check itself).
//
// Generator adequacy is asserted explicitly (see the end of this test),
// not just hoped for: a property test whose generator only ever produces
// deposits, or whose withdrawals are always trivially rejected, would pass
// this invariant vacuously.
func TestPropertyLedgerConservation_RandomEventSequences(t *testing.T) {
	const runs = 200
	const eventsPerRun = 60

	var (
		totalDeposits    int
		totalWithdrawals int
		totalRejected    int
		totalDuplicates  int
		distinctBalances = map[string]bool{}
	)

	for run := 0; run < runs; run++ {
		rng := rand.New(rand.NewSource(int64(run) * 7919))
		state := NewState()
		expected := new(big.Int) // independent tracker, in Scale-shifted integer units

		usedIDs := make([]string, 0, eventsPerRun)
		for i := 0; i < eventsPerRun; i++ {
			var id string
			// 15% of events deliberately REPLAY a previous ID, to exercise
			// (and count) the idempotency path within the same property
			// sweep that checks conservation -- both invariants share a
			// generator so neither is tested in an artificially narrow
			// corner of the state space.
			if len(usedIDs) > 0 && rng.Float64() < 0.15 {
				id = usedIDs[rng.Intn(len(usedIDs))]
			} else {
				id = fmt.Sprintf("run%d-evt%d", run, i)
				usedIDs = append(usedIDs, id)
			}

			amountUnits := int64(rng.Intn(2000)) // 0.00000000 .. 0.00002000-ish range, plenty of overlap with the balance
			amount := FormatAmount(big.NewInt(amountUnits))

			isDeposit := rng.Float64() < 0.55
			eventType := EventWithdrawn
			if isDeposit {
				eventType = EventDeposited
			}

			before := state
			wasAlreadyApplied := before.Applied[id]
			next, effects := Apply(state, Event{ID: id, Type: eventType, Amount: amount})
			state = next

			if !ConservationHolds(before, Event{ID: id, Type: eventType, Amount: amount}, state) {
				t.Fatalf("run %d event %d: ConservationHolds failed for before=%+v after=%+v", run, i, before, state)
			}

			switch eff := effects[0].(type) {
			case EffectDeposited:
				expected.Add(expected, big.NewInt(amountUnits))
				totalDeposits++
			case EffectWithdrawn:
				expected.Sub(expected, big.NewInt(amountUnits))
				totalWithdrawals++
			case EffectWithdrawalRejected:
				totalRejected++
			case EffectDuplicateIgnored:
				totalDuplicates++
				if !wasAlreadyApplied {
					t.Fatalf("run %d event %d: EffectDuplicateIgnored for an ID that was not previously applied", run, i)
				}
			default:
				t.Fatalf("run %d event %d: unexpected effect %#v", run, i, eff)
			}
		}

		wantBalance := FormatAmount(expected)
		if state.Balance != wantBalance {
			t.Fatalf("run %d: final balance = %q, want %q (independently tracked)", run, state.Balance, wantBalance)
		}
		distinctBalances[state.Balance] = true
	}

	// --- generator adequacy: state diversity floor -------------------------
	// A generator that always lands on the same handful of final balances
	// would make this property test pass while barely exercising the
	// arithmetic. With 200 runs of 60 events each, requiring at least 100
	// DISTINCT final balances is a floor, not a target -- true randomness
	// over this space produces far more.
	const minDistinctBalances = 100
	if len(distinctBalances) < minDistinctBalances {
		t.Fatalf("generator adequacy: only %d distinct final balances observed across %d runs, want >= %d -- the generator is not exploring the state space", len(distinctBalances), runs, minDistinctBalances)
	}

	// --- generator adequacy: discard ceiling --------------------------------
	// "Discards" here are the two effect classes that contribute NOTHING to
	// the conservation sum (rejected withdrawals, duplicate replays). If
	// they dominated the run, the property would mostly be testing
	// rejection/idempotency instead of arithmetic. Both are deliberately
	// present (duplicates at ~15% by construction, rejections whenever a
	// withdrawal outruns the balance) but must stay a minority.
	total := totalDeposits + totalWithdrawals + totalRejected + totalDuplicates
	discardRate := float64(totalRejected+totalDuplicates) / float64(total)
	const maxDiscardRate = 0.45
	if discardRate > maxDiscardRate {
		t.Fatalf("generator adequacy: discard rate %.2f (rejected=%d duplicate=%d of %d) exceeds ceiling %.2f -- too much of the generated corpus is being thrown away", discardRate, totalRejected, totalDuplicates, total, maxDiscardRate)
	}
	if totalDeposits == 0 || totalWithdrawals == 0 {
		t.Fatalf("generator adequacy: deposits=%d withdrawals=%d -- both must be exercised", totalDeposits, totalWithdrawals)
	}
	if totalRejected == 0 {
		t.Fatal("generator adequacy: zero rejected withdrawals observed -- the insufficient-balance branch was never exercised by this sweep")
	}
	if totalDuplicates == 0 {
		t.Fatal("generator adequacy: zero duplicate-ID replays observed -- the idempotency branch was never exercised by this sweep")
	}
}
