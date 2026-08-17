package store

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

func testIDs() IDGenerator {
	var n atomic.Uint64
	return func() string {
		v := n.Add(1)
		return fmt.Sprintf("id-%d", v)
	}
}

// provenance: derived
// verifies: outbox pattern (journal intent -> deliver -> mark done)
func TestOutbox_JournalThenPublish_MarksDelivered(t *testing.T) {
	sink := NewLogSink(nil)
	ob := NewOutbox(sink, testIDs(), 3)

	entryID, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "10"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	entry, ok := ob.Entry(entryID)
	if !ok || entry.State != StateIntent {
		t.Fatalf("entry after Journal = %+v (ok=%v), want StateIntent", entry, ok)
	}

	if err := ob.Publish(context.Background(), entryID); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	entry, _ = ob.Entry(entryID)
	if entry.State != StateDelivered {
		t.Fatalf("entry.State = %q after successful Publish, want %q", entry.State, StateDelivered)
	}
	if entry.IdempotencyKey == "" {
		t.Fatal("entry.IdempotencyKey is empty after a successful Publish")
	}
}

// provenance: derived
// verifies: outbox pattern (idempotency key generated INSIDE the retry
// closure -- the SAME key must be presented to Sink.Deliver across every
// physical retry attempt within one logical Publish call)
func TestOutbox_Publish_ReusesTheSameIdempotencyKeyAcrossRetries(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 3 // fail twice, succeed on the 3rd attempt for that key
	ob := NewOutbox(sink, testIDs(), 5)

	entryID, err := ob.Journal(domain.EffectWithdrawn{EventID: "e1", Amount: "4"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), entryID); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	entry, _ := ob.Entry(entryID)
	if got := sink.AttemptsFor(entry.IdempotencyKey); got != 3 {
		t.Fatalf("sink saw %d attempts under the final idempotency key, want 3 (all retries shared one key)", got)
	}
	if entry.Attempts != 3 {
		t.Fatalf("entry.Attempts = %d, want 3", entry.Attempts)
	}
}

// provenance: derived
// verifies: outbox pattern (a SEPARATE logical Publish call for a
// DIFFERENT entry gets its OWN idempotency key -- keys are not globally
// reused, only reused WITHIN one entry's retry loop)
func TestOutbox_Publish_DifferentEntriesGetDifferentIdempotencyKeys(t *testing.T) {
	sink := NewLogSink(nil)
	ob := NewOutbox(sink, testIDs(), 3)

	id1, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	id2, _ := ob.Journal(domain.EffectDeposited{EventID: "e2", Amount: "2"})
	if err := ob.Publish(context.Background(), id1); err != nil {
		t.Fatalf("Publish id1: %v", err)
	}
	if err := ob.Publish(context.Background(), id2); err != nil {
		t.Fatalf("Publish id2: %v", err)
	}
	e1, _ := ob.Entry(id1)
	e2, _ := ob.Entry(id2)
	if e1.IdempotencyKey == e2.IdempotencyKey {
		t.Fatalf("two different entries got the same idempotency key: %q", e1.IdempotencyKey)
	}
}

// provenance: derived
// verifies: outbox pattern (max attempts exhausted -> StateFailed, a
// Reconcile candidate -- never retried forever)
func TestOutbox_Publish_ExhaustsMaxAttemptsAndMarksFailed(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 100 // never succeeds within maxAttempts
	ob := NewOutbox(sink, testIDs(), 3)

	entryID, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err := ob.Publish(context.Background(), entryID); err == nil {
		t.Fatal("Publish did not return an error after exhausting max attempts")
	}
	entry, _ := ob.Entry(entryID)
	if entry.State != StateFailed {
		t.Fatalf("entry.State = %q, want %q", entry.State, StateFailed)
	}
	if entry.Attempts != 3 {
		t.Fatalf("entry.Attempts = %d, want exactly maxAttempts=3 (never retried forever)", entry.Attempts)
	}
}

// provenance: derived
// verifies: recovery ("journal says X, world says Y" table-driven recovery
// -- tier-policy: recovery.tabular_recovery_tests required) -- Reconcile
// resumes every StateIntent/StateFailed entry and, once the sink recovers,
// delivers them.
func TestOutbox_Reconcile_ResumesPendingEntries(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 100
	ob := NewOutbox(sink, testIDs(), 2)

	id1, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	id2, _ := ob.Journal(domain.EffectDeposited{EventID: "e2", Amount: "2"})
	_ = ob.Publish(context.Background(), id1) // exhausts attempts -> StateFailed
	// id2 is left in StateIntent (Publish never called): both are "pending".

	if got := ob.Pending(); len(got) != 2 {
		t.Fatalf("Pending() = %d entries, want 2 (id1 failed, id2 still-intent)", len(got))
	}

	sink.FailUntilAttempt = 0 // the world recovers
	result := ob.Reconcile(context.Background())
	if result.Resumed != 2 || result.Delivered != 2 || result.StillDown != 0 {
		t.Fatalf("Reconcile() = %+v, want Resumed=2 Delivered=2 StillDown=0", result)
	}
	for _, id := range []string{id1, id2} {
		e, _ := ob.Entry(id)
		if e.State != StateDelivered {
			t.Fatalf("entry %s state = %q after Reconcile, want %q", id, e.State, StateDelivered)
		}
	}
	if got := ob.Pending(); len(got) != 0 {
		t.Fatalf("Pending() after a fully successful Reconcile = %d, want 0", len(got))
	}
}

// provenance: derived
// verifies: outbox pattern (Publish against an unknown entry id fails
// loudly rather than silently doing nothing)
func TestOutbox_Publish_UnknownEntryIDErrors(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	if err := ob.Publish(context.Background(), "does-not-exist"); err == nil {
		t.Fatal("Publish(unknown entry id) did not error")
	}
}

// provenance: derived
// verifies: outbox pattern (Entry lookup on an unknown id reports ok=false
// rather than a zero-value Entry that looks like a real one)
func TestOutbox_Entry_UnknownIDReportsNotOK(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	if _, ok := ob.Entry("does-not-exist"); ok {
		t.Fatal("Entry(unknown id) reported ok=true")
	}
}

// provenance: derived
// verifies: outbox pattern (NewOutbox defaults a non-positive maxAttempts
// to a sane floor rather than never retrying at all)
func TestNewOutbox_DefaultsNonPositiveMaxAttempts(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 4
	ob := NewOutbox(sink, testIDs(), 0) // 0 -> defaults to 5
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v (want the default attempt budget to cover 4 attempts)", err)
	}
}
