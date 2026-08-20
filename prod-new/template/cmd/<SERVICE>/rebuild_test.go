package main

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
)

// crashSink records what it was asked to deliver.
type crashSink struct{ delivered []string }

func (s *crashSink) Deliver(_ context.Context, key string, _ store.Entry) error {
	s.delivered = append(s.delivered, key)
	return nil
}

// provenance: derived
// verifies: effect_journal_atomic -- an effect whose event was journaled but
// whose outbox entry never was IS recovered at boot and still delivered.
//
// This reproduces the exact window: process() appends the event to the durable
// log, commits the state, releases the lock, and only then journals the
// effect. Two durable writes, no transaction. Crashing between them used to
// lose the effect permanently, because the event replays and RebuildFrom
// discards effects.
//
// The crash is simulated the only honest way -- by writing the event to the
// log and never journaling its effect, which is precisely the on-disk state a
// process killed in that window leaves behind.
func TestRebuildOutboxFromLog_RecoversEffectsLostInTheCommitWindow(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")

	// --- the crash: events are durable, their effects were never journaled
	log, err := eventlog.Open(eventLogPath)
	if err != nil {
		t.Fatalf("open event log: %v", err)
	}
	for _, e := range []domain.Event{
		{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
		{ID: "e2", Type: domain.EventDeposited, Amount: "5"},
	} {
		if err := log.Append(context.Background(), e); err != nil {
			t.Fatalf("append %s: %v", e.ID, err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// --- boot: a fresh durable outbox that has never seen those effects
	sink := &crashSink{}
	outbox, err := store.OpenDurable(filepath.Join(dir, "outbox.jsonl"), sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("open outbox: %v", err)
	}
	defer func() { _ = outbox.Close() }()

	recovered, err := rebuildOutboxFromLog(eventLogPath, outbox)
	if err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if recovered != 2 {
		t.Fatalf("recovered = %d, want 2 -- the effects lost in the commit window "+
			"were not rebuilt from the event log", recovered)
	}
	if got := len(outbox.Pending()); got != 2 {
		t.Fatalf("pending = %d, want 2", got)
	}

	// --- and they deliver, which is the point of recovering them
	result := outbox.Reconcile(context.Background())
	if result.Delivered != 2 {
		t.Fatalf("Reconcile delivered %d, want 2", result.Delivered)
	}
	if len(sink.delivered) != 2 {
		t.Fatalf("sink saw %d deliveries, want 2", len(sink.delivered))
	}
}

// provenance: derived
// verifies: the complement, and the half that keeps recovery from becoming a
// redelivery storm -- effects the outbox ALREADY knows are not journaled
// again. Without this, every restart would re-deliver the entire deliverable
// history, which is a worse failure than the one the rebuild fixes.
func TestRebuildOutboxFromLog_DoesNotRejournalWhatItAlreadyKnows(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")
	outboxPath := filepath.Join(dir, "outbox.jsonl")

	log, err := eventlog.Open(eventLogPath)
	if err != nil {
		t.Fatalf("open event log: %v", err)
	}
	if err := log.Append(context.Background(), domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"}); err != nil {
		t.Fatalf("append: %v", err)
	}
	if err := log.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	sink := &crashSink{}
	outbox, err := store.OpenDurable(outboxPath, sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("open outbox: %v", err)
	}
	first, err := rebuildOutboxFromLog(eventLogPath, outbox)
	if err != nil {
		t.Fatalf("first rebuild: %v", err)
	}
	if first != 1 {
		t.Fatalf("first rebuild recovered %d, want 1", first)
	}
	if err := outbox.Close(); err != nil {
		t.Fatalf("close outbox: %v", err)
	}

	// Boot again over the SAME durable outbox log. The identity is derived,
	// so the second pass must recognise what the first one journaled.
	reopened, err := store.OpenDurable(outboxPath, sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("reopen outbox: %v", err)
	}
	defer func() { _ = reopened.Close() }()

	second, err := rebuildOutboxFromLog(eventLogPath, reopened)
	if err != nil {
		t.Fatalf("second rebuild: %v", err)
	}
	if second != 0 {
		t.Fatalf("second rebuild recovered %d, want 0 -- every restart would "+
			"re-journal the whole deliverable history", second)
	}
}

// provenance: derived
// verifies: the recovered effect presents the SAME idempotency key its first
// attempt would have. A resumed delivery that arrives under a fresh key reads
// to the sink as a brand-new effect, so the deduplication that makes
// at-least-once tolerable does nothing -- recovery would trade a lost effect
// for a duplicated one.
func TestRebuildOutboxFromLog_RecoveredEffectCarriesItsDerivedIdentity(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")

	log, err := eventlog.Open(eventLogPath)
	if err != nil {
		t.Fatalf("open event log: %v", err)
	}
	if err := log.Append(context.Background(), domain.Event{ID: "ev1", Type: domain.EventDeposited, Amount: "1"}); err != nil {
		t.Fatalf("append: %v", err)
	}
	_ = log.Close()

	sink := &crashSink{}
	outbox, err := store.OpenDurable(filepath.Join(dir, "outbox.jsonl"), sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("open outbox: %v", err)
	}
	defer func() { _ = outbox.Close() }()

	if _, err := rebuildOutboxFromLog(eventLogPath, outbox); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	pending := outbox.Pending()
	if len(pending) != 1 {
		t.Fatalf("pending = %d, want 1", len(pending))
	}
	if got, want := pending[0].IdempotencyKey, "ev1#0"; got != want {
		t.Fatalf("idempotency key = %q, want the derived %q -- a resumed delivery "+
			"under a fresh key is a duplicate, not a resumption", got, want)
	}
}
