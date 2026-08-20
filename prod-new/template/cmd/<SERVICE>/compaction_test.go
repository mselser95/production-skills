package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
	"github.com/<OWNER>/<SERVICE>/internal/platform/outboxlog"
)

// seedEvents writes events to a fresh durable event log at path.
func seedEvents(t *testing.T, path string, events ...domain.Event) {
	t.Helper()
	log, err := eventlog.Open(path)
	if err != nil {
		t.Fatalf("open event log: %v", err)
	}
	for _, e := range events {
		if err := log.Append(context.Background(), e); err != nil {
			t.Fatalf("append %s: %v", e.ID, err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatalf("close event log: %v", err)
	}
}

// boot runs the composition root's outbox half: open the durable outbox,
// rebuild from the event log recording what is re-derivable, compact, then
// drain. It returns the outbox so the caller can inspect it, and the caller
// closes it.
func boot(t *testing.T, eventLogPath, outboxPath string, sink store.Sink) *store.Outbox {
	t.Helper()
	outbox, err := store.OpenDurable(outboxPath, sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	rederivable := newRederivable(outbox)
	if _, err := rebuildOutboxFromLog(eventLogPath, rederivable); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	compactOutboxLog(context.Background(), outbox, rederivable, discardLogger())
	return outbox
}

// provenance: derived
// verifies: THE DATA-INTEGRITY REGRESSION a literal reading of "keep only
// entries with no terminal record" produces.
//
// The outbox log doubles as the delivery watermark: rebuildOutboxFromLog asks
// KnowsIdentity, and an identity the log does not carry reads as an effect
// lost between the two fsyncs, so it is re-journaled and DELIVERED AGAIN.
// Compaction that dropped delivered entries unconditionally would therefore
// republish every still-re-derivable effect on EVERY boot -- a redelivery
// storm that grows with the event log, produced by a change whose whole
// justification was hygiene.
//
// This test boots twice over the same pair of logs and asserts the sink saw
// each effect exactly once.
func TestCompactOutboxLog_DoesNotRepublishDeliveredEffectsOnTheNextBoot(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")
	outboxPath := filepath.Join(dir, "outbox.jsonl")
	seedEvents(t, eventLogPath,
		domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
		domain.Event{ID: "e2", Type: domain.EventWithdrawn, Amount: "3"},
	)

	sink := &crashSink{}

	first := boot(t, eventLogPath, outboxPath, sink)
	if got := first.Reconcile(context.Background()).Delivered; got != 2 {
		t.Fatalf("boot 1 delivered %d, want 2", got)
	}
	// Compact AFTER delivery too: this is the state the next boot inherits.
	rederivable := newRederivable(first)
	if _, err := rebuildOutboxFromLog(eventLogPath, rederivable); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	compactOutboxLog(context.Background(), first, rederivable, discardLogger())
	if err := first.Close(); err != nil {
		t.Fatalf("close boot 1: %v", err)
	}
	if len(sink.delivered) != 2 {
		t.Fatalf("boot 1 sink saw %d deliveries, want 2", len(sink.delivered))
	}

	second := boot(t, eventLogPath, outboxPath, sink)
	defer func() { _ = second.Close() }()
	if got := second.Reconcile(context.Background()).Delivered; got != 0 {
		t.Fatalf("boot 2 delivered %d effects; every one is a REPUBLISH of something the sink already has", got)
	}
	if len(sink.delivered) != 2 {
		t.Fatalf("sink saw %d deliveries across two boots, want 2 -- compaction dropped a watermark the rebuild needed: %v",
			len(sink.delivered), sink.delivered)
	}
}

// provenance: derived
// verifies: the retain guard is LOAD-BEARING, shown constructively rather than
// asserted. Compacting the SAME state with a guard that retains nothing --
// which is exactly what a literal "drop everything terminal" implementation
// does -- makes the next boot re-journal and redeliver. If this test ever goes
// quiet, the guard above stopped being what prevents the storm.
func TestCompactOutboxLog_WithoutTheRetainGuardTheNextBootRedelivers(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")
	outboxPath := filepath.Join(dir, "outbox.jsonl")
	seedEvents(t, eventLogPath,
		domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
	)

	sink := &crashSink{}
	first := boot(t, eventLogPath, outboxPath, sink)
	if got := first.Reconcile(context.Background()).Delivered; got != 1 {
		t.Fatalf("boot 1 delivered %d, want 1", got)
	}
	// The guard, removed: nothing is retained.
	if _, err := first.Compact(func(string) bool { return false }); err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	second := boot(t, eventLogPath, outboxPath, sink)
	defer func() { _ = second.Close() }()
	if got := second.Reconcile(context.Background()).Delivered; got != 1 {
		t.Fatalf("boot 2 delivered %d, want 1 -- without the guard this SHOULD republish, "+
			"and a test that no longer observes it is no longer evidence the guard matters", got)
	}
	if len(sink.delivered) != 2 {
		t.Fatalf("sink saw %d deliveries, want 2 (the republish) -- %v", len(sink.delivered), sink.delivered)
	}
}

// provenance: derived
// verifies: compaction still RECLAIMS. The retain guard keeps what the event
// log can re-derive; an entry the walk cannot reach -- here one journaled
// directly, with an identity no event produces -- is folded away, so the log
// tracks the live set rather than lifetime effect volume.
func TestCompactOutboxLog_ReclaimsWhatTheEventLogCanNoLongerRederive(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")
	outboxPath := filepath.Join(dir, "outbox.jsonl")
	seedEvents(t, eventLogPath, domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"})

	sink := &crashSink{}
	outbox, err := store.OpenDurable(outboxPath, sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	// An entry with no event behind it: nothing will ever re-derive it.
	orphan, err := outbox.Journal(domain.EffectDeposited{EventID: "not-in-the-log", Amount: "99"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := outbox.Publish(context.Background(), orphan); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	rederivable := newRederivable(outbox)
	if _, err := rebuildOutboxFromLog(eventLogPath, rederivable); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if got := outbox.Reconcile(context.Background()).Delivered; got != 1 {
		t.Fatalf("delivered %d, want the recovered effect", got)
	}
	sizeBefore := fileSize(t, outboxPath)

	compactOutboxLog(context.Background(), outbox, rederivable, discardLogger())
	runs, dropped, reclaimed := outbox.CompactionStats()
	if runs != 1 {
		t.Fatalf("runs = %d, want 1", runs)
	}
	if dropped != 1 {
		t.Fatalf("entriesDropped = %d, want exactly the orphan", dropped)
	}
	if reclaimed <= 0 {
		t.Fatalf("bytesReclaimed = %d, want > 0", reclaimed)
	}
	if got := fileSize(t, outboxPath); got >= sizeBefore {
		t.Fatalf("log is %d bytes, was %d -- nothing was reclaimed on disk", got, sizeBefore)
	}
	if _, ok := outbox.Entry(orphan); ok {
		// In-memory retention is separate; what must be gone is the RECORD.
		t.Log("orphan still in memory, which is expected -- the assertion is about the log")
	}
	if err := outbox.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	records, err := outboxlog.Replay(outboxPath)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	for _, rec := range records {
		if rec.EntryID == orphan {
			t.Fatalf("the orphan entry is still in the log after compaction")
		}
	}
	// ... and the re-derivable one is still there, which is what keeps the
	// next boot from republishing it.
	reopened, err := store.OpenDurable(outboxPath, sink, ids.Real{}.NewID, 3)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if !reopened.KnowsIdentity("e1#0") {
		t.Fatalf("the watermark for e1#0 is gone; the next boot would redeliver it")
	}
}

// provenance: derived
// verifies: a HEALTHY boot spends no fsync and no rename. There is nothing
// terminal to fold on a service whose effects are all still in flight, and
// rewriting the log to produce a byte-identical copy would widen the window a
// crash can land in for zero reclaim.
func TestCompactOutboxLog_HealthyBootDoesNotRewriteTheLog(t *testing.T) {
	dir := t.TempDir()
	eventLogPath := filepath.Join(dir, "eventlog.jsonl")
	outboxPath := filepath.Join(dir, "outbox.jsonl")
	seedEvents(t, eventLogPath, domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"})

	sink := &crashSink{}
	outbox := boot(t, eventLogPath, outboxPath, sink)
	defer func() { _ = outbox.Close() }()

	runs, dropped, reclaimed := outbox.CompactionStats()
	if runs != 1 {
		t.Fatalf("runs = %d, want 1 -- compaction must run even when it reclaims nothing, or the counter cannot distinguish the two", runs)
	}
	if dropped != 0 || reclaimed != 0 {
		t.Fatalf("dropped=%d reclaimed=%d on a boot with nothing terminal to fold", dropped, reclaimed)
	}
	if _, err := os.Stat(outboxPath + ".compact"); err == nil {
		t.Fatalf("a .compact replacement was left beside the log")
	}
}
