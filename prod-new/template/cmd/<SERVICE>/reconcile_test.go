package main

import (
	"context"
	"errors"
	"log/slog"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
	"github.com/<OWNER>/<SERVICE>/internal/platform/outboxlog"
)

// deadSink is a Sink that is down and stays down.
type deadSink struct{}

func (deadSink) Deliver(context.Context, string, store.Entry) error {
	return errors.New("test: sink is down")
}

// recoveringSink is down until Recover is called, and records every key it
// accepted afterwards. It counts attempts while down, so a test can assert
// the loop kept TRYING rather than merely that it eventually succeeded.
type recoveringSink struct {
	mu        sync.Mutex
	up        bool
	attempts  int
	delivered []string
}

func (s *recoveringSink) Deliver(_ context.Context, idempotencyKey string, _ store.Entry) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.attempts++
	if !s.up {
		return errors.New("test: sink is down")
	}
	s.delivered = append(s.delivered, idempotencyKey)
	return nil
}

func (s *recoveringSink) Recover() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.up = true
}

func (s *recoveringSink) snapshot() (attempts int, delivered []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attempts, append([]string(nil), s.delivered...)
}

func discardLogger() *slog.Logger {
	return slog.New(slog.DiscardHandler)
}

// outboxEntryState reads one entry's state back out of the DURABLE journal,
// which is the only surface a test outside the process can observe -- and
// therefore the only honest way to assert that a separately-running
// composition root delivered something.
func outboxEntryState(path, entryID string) (string, error) {
	records, err := outboxlog.Replay(path)
	if err != nil {
		return "", err
	}
	snapshots, err := outboxlog.Rebuild(records)
	if err != nil {
		return "", err
	}
	for _, snapshot := range snapshots {
		if snapshot.EntryID == entryID {
			return snapshot.State, nil
		}
	}
	return "", nil
}

// provenance: derived
// verifies: auto-recovery / self_recovery -- an outbox entry stalled by a
// sink outage DRAINS with nobody calling Reconcile, because the composition
// root drives it.
//
// This test exists to prove the WIRING, not the mechanism. Outbox.Reconcile
// had two passing tests of its own and no caller anywhere in production code
// for the life of the scaffold; a suite cannot tell an injected mechanism
// from an uninjected one, which is exactly why this one boots run() itself
// instead of calling the loop. Deleting the goroutine from run() must turn
// this RED -- that is the assertion, and calling reconcileLoop here by hand
// would quietly retire it.
//
// The failure is induced the only honest way: a durable intent is journaled
// and published against a sink that is DOWN, leaving the on-disk state a
// process killed during an outage leaves behind. run() then boots against
// that journal with a working sink, and recovery must happen unaided.
func TestRun_DrainsAStalledOutboxEntryWithNobodyCallingReconcile(t *testing.T) {
	dir := t.TempDir()
	// config.Load has no override for CHECKPOINT_PATH, so run() would create
	// ./data relative to the working directory. Move it somewhere disposable.
	t.Chdir(t.TempDir())

	outboxPath := filepath.Join(dir, "outbox.jsonl")

	// --- the stall: an intent whose sink was down, durably recorded -------
	stalled, err := store.OpenDurable(outboxPath, deadSink{}, ids.Real{}.NewID, 1)
	if err != nil {
		t.Fatalf("open outbox: %v", err)
	}
	entryID, err := stalled.Journal(domain.EffectDeposited{EventID: "e1", Amount: "10"})
	if err != nil {
		t.Fatalf("journal: %v", err)
	}
	if err := stalled.Publish(context.Background(), entryID); err == nil {
		t.Fatal("precondition: Publish against a dead sink must fail")
	}
	if err := stalled.Close(); err != nil {
		t.Fatalf("close outbox: %v", err)
	}
	if state, err := outboxEntryState(outboxPath, entryID); err != nil || state != outboxlog.StateFailed {
		t.Fatalf("precondition: entry state = %q (err %v), want %q", state, err, outboxlog.StateFailed)
	}

	// --- boot the real composition root, with a sink that works ----------
	t.Setenv("HEALTH_PORT", "0")
	t.Setenv("EVENTLOG_PATH", filepath.Join(dir, "eventlog.jsonl"))
	t.Setenv("OUTBOX_LOG_PATH", outboxPath)
	t.Setenv("LOG_LEVEL", "error")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- run(ctx) }()

	// The budget is deliberately SHORTER than the production ticker: the
	// ticker cannot satisfy it, so a pass here is also evidence the boot-time
	// wake-up fired. Asserted rather than assumed, because retuning the
	// interval would otherwise silently retire that half.
	const budget = 5 * time.Second
	if budget >= outboxReconcileInterval {
		t.Fatalf("this test proves the wake-up only while the budget (%s) is under outboxReconcileInterval (%s)",
			budget, outboxReconcileInterval)
	}

	deadline := time.After(budget)
	var lastState string
	var lastErr error
	for {
		lastState, lastErr = outboxEntryState(outboxPath, entryID)
		if lastState == outboxlog.StateDelivered {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("run returned before the entry drained: %v", err)
		case <-deadline:
			cancel()
			<-done
			t.Fatalf("the stalled entry never drained (state %q, err %v): nothing in the composition root drives Outbox.Reconcile",
				lastState, lastErr)
		case <-time.After(5 * time.Millisecond):
		}
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("run: %v", err)
	}
}

// provenance: derived
// verifies: reconciliation -- the loop keeps ATTEMPTING a stalled entry while
// the sink is down and delivers it once the sink comes back, with nobody
// calling Reconcile by hand.
//
// This is the TICKER half, and it is the half that recovers from the sink. An
// entry the sink rejected produces nothing that would signal on its own
// behalf, so a wake-only loop would detect the delivery failure and never
// return from it -- which is the defect dimension 13 exists to catch.
func TestReconcileLoop_RetriesAStalledEntryUntilTheSinkRecovers(t *testing.T) {
	sink := &recoveringSink{}
	outbox := store.NewOutbox(sink, ids.Real{}.NewID, 1)

	wake, notifyPending := newPendingWake()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		reconcileLoop(ctx, outbox, wake, discardLogger(), 5*time.Millisecond)
	}()

	entryID, err := outbox.Journal(domain.EffectDeposited{EventID: "e1", Amount: "10"})
	if err != nil {
		t.Fatalf("journal: %v", err)
	}
	entry, ok := outbox.Entry(entryID)
	if !ok {
		t.Fatalf("entry %q not found after journaling", entryID)
	}
	notifyPending()

	// --- while the sink is down: retried, never delivered, never dropped --
	waitFor(t, 5*time.Second, "the loop to retry a stalled entry", func() bool {
		attempts, _ := sink.snapshot()
		return attempts >= 3
	})
	if _, delivered := sink.snapshot(); len(delivered) != 0 {
		t.Fatalf("sink delivered %v while it was down", delivered)
	}
	if got, _ := outbox.Entry(entryID); got.State == store.StateDelivered {
		t.Fatal("entry reported delivered while the sink was down")
	}

	// --- the sink comes back: recovery is unaided -------------------------
	sink.Recover()
	waitFor(t, 5*time.Second, "the stalled entry to drain once the sink recovered", func() bool {
		got, _ := outbox.Entry(entryID)
		return got.State == store.StateDelivered
	})

	_, delivered := sink.snapshot()
	if len(delivered) != 1 || delivered[0] != entry.IdempotencyKey {
		t.Fatalf("sink saw keys %v, want exactly [%s] -- a resumed delivery must reuse the ENTRY's key",
			delivered, entry.IdempotencyKey)
	}

	cancel()
	<-stopped
}

// provenance: derived
// verifies: the wake-up channel never blocks its signaller and drops a second
// signal rather than queueing it.
//
// The drop is the point. This notifier is called from the boot path, and a
// send that could block would put a reconciler waiting on a dead sink in
// front of it -- the exact coupling moving delivery off the journal path
// removes.
func TestNewPendingWake_DropsASecondSignalAndNeverBlocks(t *testing.T) {
	wake, notifyPending := newPendingWake()

	signalled := make(chan struct{})
	go func() {
		defer close(signalled)
		notifyPending()
		notifyPending() // must be dropped, not block on a full buffer
		notifyPending()
	}()
	select {
	case <-signalled:
	case <-time.After(5 * time.Second):
		t.Fatal("the notifier blocked: a full wake buffer must drop the signal, never wait")
	}

	select {
	case <-wake:
	default:
		t.Fatal("no wake-up was delivered")
	}
	select {
	case <-wake:
		t.Fatal("a second wake-up was queued: the buffer must hold exactly one pending drain")
	default:
	}
}

// waitFor polls cond until it holds or budget elapses, failing with what was
// being waited on.
func waitFor(t *testing.T, budget time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.After(budget)
	for {
		if cond() {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("timed out after %s waiting for %s", budget, what)
		case <-time.After(2 * time.Millisecond):
		}
	}
}
