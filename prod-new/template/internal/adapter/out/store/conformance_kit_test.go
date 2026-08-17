package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/verification/conformance"
)

// provenance: derived
// verifies: capability units_notification / external_effect conformance kit
// (tier-policy: conformance kits GATE at T0; this template ships them at
// T0-strength from the first commit regardless of the eventual declared
// tier)
//
// internal/adapter/out/store.Outbox is this template's ONE wired
// external_effect adapter -- see verification/conformance/README.md.
func TestOutbox_PassesExternalEffectConformanceKit(t *testing.T) {
	conformance.ExternalEffectKit(t, driveExternalEffect)
}

func driveExternalEffect(t *testing.T, scenario string) {
	switch scenario {
	case "rejected":
		// A withdrawal that would overdraw is rejected by domain.Apply
		// BEFORE internal/app.Ledger ever calls EffectPublisher.Journal
		// (see internal/app/ledger.go's process(): only
		// EffectDeposited/EffectWithdrawn reach the outbox at all) -- there
		// is no "rejected" outcome reachable from this adapter's own port.
		// See internal/app's TestLedger_Withdraw_InsufficientBalanceNeverJournalsAnOutboxEntry
		// for where this obligation is actually proven.
		t.Skip("rejection happens upstream in domain.Apply; this adapter never receives a rejected effect to journal")

	case "timeout_before_acceptance":
		driveTimeoutBeforeAcceptance(t)

	case "timeout_after_acceptance", "duplicate_response", "retry_on_unknown_state":
		// All three scenarios share one mechanism at this layer: the
		// receiver processed the effect but the caller could not confirm
		// it (ack lost / connection dropped / ambiguous response), so the
		// SAME idempotency key is retried. The obligation is "at most one
		// real processing per key", proven directly against
		// ackLostOnceSink below.
		driveAckLostRetriedWithSameKey(t)

	case "malformed_response":
		driveMalformedResponseExhaustsAttempts(t)

	case "unavailable":
		driveUnavailableThenReconciles(t)

	case "extreme_latency":
		driveExtremeLatencyRespectsContext(t)

	case "crash_between_decision_and_effect":
		driveCrashBetweenJournalAndPublish(t)

	default:
		t.Fatalf("conformance kit scenario %q has no driver in this adapter's test -- add one instead of letting it silently pass", scenario)
	}
}

func driveTimeoutBeforeAcceptance(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 2 // first attempt never reaches "acceptance"
	ob := NewOutbox(sink, testIDs(), 3)
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v (should have succeeded on retry)", err)
	}
	entry, _ := ob.Entry(id)
	if entry.State != StateDelivered {
		t.Fatalf("entry.State = %q, want %q after a retry past the pre-acceptance timeout", entry.State, StateDelivered)
	}
}

// ackLostOnceSink models a receiver that PROCESSES the effect exactly once
// per idempotency key but whose first acknowledgment is lost (a real
// timeout/duplicate/unknown-state condition): the first Deliver call for a
// given key returns an error even though the "processing" already
// happened; every subsequent call with the SAME key is a safe, idempotent
// no-op success. If Outbox generated a DIFFERENT key per retry, this fake
// would record more than one real processing per logical delivery --
// exactly the bug class the idempotency-key-inside-the-closure design
// prevents.
type ackLostOnceSink struct {
	mu        sync.Mutex
	processed map[string]int
	seenKey   map[string]bool
}

func newAckLostOnceSink() *ackLostOnceSink {
	return &ackLostOnceSink{processed: map[string]int{}, seenKey: map[string]bool{}}
}

func (s *ackLostOnceSink) Deliver(ctx context.Context, key string, entry Entry) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.seenKey[key] {
		s.seenKey[key] = true
		s.processed[key]++
		return errors.New("simulated: receiver processed the effect but the acknowledgment was lost")
	}
	return nil
}

func (s *ackLostOnceSink) processedCount(key string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.processed[key]
}

func driveAckLostRetriedWithSameKey(t *testing.T) {
	sink := newAckLostOnceSink()
	ob := NewOutbox(sink, testIDs(), 3)
	id, err := ob.Journal(domain.EffectWithdrawn{EventID: "e1", Amount: "4"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v (should have succeeded once the retry's idempotent replay was accepted)", err)
	}
	entry, _ := ob.Entry(id)
	if entry.State != StateDelivered {
		t.Fatalf("entry.State = %q, want %q", entry.State, StateDelivered)
	}
	if got := sink.processedCount(entry.IdempotencyKey); got != 1 {
		t.Fatalf("receiver processed the effect %d times under key %s, want exactly 1 (idempotency-key-inside-the-closure obligation)", got, entry.IdempotencyKey)
	}
}

func driveMalformedResponseExhaustsAttempts(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 1000 // every response is treated as unusable
	ob := NewOutbox(sink, testIDs(), 3)
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err == nil {
		t.Fatal("Publish succeeded despite every response being malformed/unusable")
	}
	entry, _ := ob.Entry(id)
	if entry.State != StateFailed {
		t.Fatalf("entry.State = %q, want %q (never retried forever)", entry.State, StateFailed)
	}
}

func driveUnavailableThenReconciles(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 1000
	ob := NewOutbox(sink, testIDs(), 2)
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err == nil {
		t.Fatal("Publish succeeded while the sink was unavailable")
	}
	sink.FailUntilAttempt = 0 // the external system recovers
	result := ob.Reconcile(context.Background())
	if result.Delivered != 1 {
		t.Fatalf("Reconcile() = %+v, want the entry recovered once the sink was available again", result)
	}
}

// slowSink respects context cancellation instead of always resolving
// immediately, so extreme_latency is a real timeout, not a fast-failing
// stand-in.
type slowSink struct {
	delay time.Duration
}

func (s *slowSink) Deliver(ctx context.Context, key string, entry Entry) error {
	select {
	case <-time.After(s.delay):
		return nil
	case <-ctx.Done():
		return fmt.Errorf("slowSink: %w", ctx.Err())
	}
}

func driveExtremeLatencyRespectsContext(t *testing.T) {
	ob := NewOutbox(&slowSink{delay: time.Hour}, testIDs(), 1)
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := ob.Publish(ctx, id); err == nil {
		t.Fatal("Publish against an hour-long delay with a 20ms context deadline did not error")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("Publish took %v to respect a 20ms context deadline -- extreme latency must not block the caller past its own timeout", elapsed)
	}
}

func driveCrashBetweenJournalAndPublish(t *testing.T) {
	sink := NewLogSink(nil)
	ob := NewOutbox(sink, testIDs(), 3)
	// Journal records the intent -- this is the durable step that survives
	// a crash. Publish is deliberately NEVER called here, modeling a
	// process that journaled the intent and then died before attempting
	// delivery.
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	entry, _ := ob.Entry(id)
	if entry.State != StateIntent {
		t.Fatalf("entry.State = %q immediately after Journal, want %q", entry.State, StateIntent)
	}
	// A fresh Reconcile pass (what the NEXT process, or a recovery timer,
	// runs) must find and resume it without needing Publish to have ever
	// been called.
	result := ob.Reconcile(context.Background())
	if result.Delivered != 1 {
		t.Fatalf("Reconcile() = %+v, want the never-published intent recovered", result)
	}
}
