package app

import (
	"context"
	"fmt"
	"math/big"
	"sync"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/verification/conformance"
)

// provenance: derived
// verifies: capability units_ledger / source_of_truth conformance kit
// (tier-policy: conformance kits GATE at T0)
//
// internal/app.Ledger is this template's source_of_truth capability. Its
// scenario checklist is written for a durable store with a client/server
// boundary and a commit protocol; Ledger is in-process, single-writer,
// guarded by its own mutex -- most of the checklist is N/A by
// construction (see each t.Skip's reason below), but serialization_conflict
// (concurrent writers racing the same aggregate) has real teeth here and is
// exercised for real, under -race.
func TestLedger_PassesSourceOfTruthConformanceKit(t *testing.T) {
	conformance.SourceOfTruthKit(t, driveSourceOfTruth)
}

func driveSourceOfTruth(t *testing.T, scenario string) {
	switch scenario {
	case "serialization_conflict":
		driveSerializationConflict(t)
	case "deadlock":
		t.Skip("Ledger.process takes a single mutex around the Apply step and holds it for no externally-observable operation (no nested lock acquisition, no callout to another lock while held) -- there is no second lock this structure could deadlock against")
	case "timeout":
		t.Skip("no network/IO call happens while Ledger's mutex is held (journal.Append and effects.Journal/Publish are called OUTSIDE the critical section, or with the state already committed -- see process()'s comments); there is nothing to time out against inside the commit path itself")
	case "commit_ok_response_lost":
		t.Skip("this is an in-process structure: the caller of Deposit/Withdraw receives the CommandOutcome directly from the same call stack that performed the commit -- there is no separate ack channel whose response could be lost independently of the commit itself")
	case "connection_dies_before_commit", "connection_dies_after_commit":
		t.Skip("no client/server connection exists between a caller and Ledger -- both are the SAME process; a caller's own crash before/after the Deposit/Withdraw call returning is a durability question for internal/platform/eventlog (the durable journal), which is exercised by TestSvc_RealEventLogAndRealTCP_DepositAndWithdrawSurviveARestart (internal/e2e, integration-tagged) and by internal/platform/eventlog's own replay tests")
	case "restore_from_backup":
		t.Skip("recovery here is FULL-LOG REPLAY (internal/platform/eventlog.Rebuild), not a backup/restore of a point-in-time snapshot -- see production.yaml's backup_restore_test ratified decline for why a traditional backup/restore test does not apply to this scaffold's storage choice")
	default:
		t.Fatalf("conformance kit scenario %q has no driver in this test -- add one instead of letting it silently pass", scenario)
	}
}

// driveSerializationConflict runs many concurrent Deposit/Withdraw calls
// against ONE Ledger from multiple goroutines (run this test file's whole
// suite with -race, as `make race`/`make verify` always do) and asserts
// the ledger's own conservation invariant still holds afterward --
// consistency_semantics's real teeth for a single-writer, mutex-guarded,
// in-memory structure.
func driveSerializationConflict(t *testing.T) {
	l, _, _ := newTestLedger()
	const workers = 20
	const depositsPerWorker = 25

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := 0; i < depositsPerWorker; i++ {
				id := fmt.Sprintf("w%d-e%d", worker, i)
				if _, err := l.Deposit(context.Background(), id, "1"); err != nil {
					t.Errorf("concurrent Deposit(%s): %v", id, err)
				}
			}
		}(w)
	}
	wg.Wait()

	oneUnit := big.NewInt(1)
	oneUnit.Exp(big.NewInt(10), big.NewInt(domain.Scale), nil) // "1.00000000" in fixed-point units
	total := new(big.Int).Mul(oneUnit, big.NewInt(int64(workers*depositsPerWorker)))
	want := domain.FormatAmount(total)
	if got := l.State().Balance; got != want {
		t.Fatalf("balance after %d concurrent deposits = %q, want %q -- a lost update under concurrent access", workers*depositsPerWorker, got, want)
	}
	if got := l.ConservationViolations(); got != 0 {
		t.Fatalf("ConservationViolations=%d after concurrent access, want 0", got)
	}
}
