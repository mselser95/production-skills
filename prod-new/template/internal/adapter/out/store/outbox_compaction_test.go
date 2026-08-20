package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: derived
// verifies: the liability outbox-log-grows-without-compaction, at the layer
// that owns the identity mapping -- a DELIVERED entry nothing can re-derive is
// folded out of the durable log, and the entry stops replaying at boot.
func TestOutbox_Compact_DropsDeliveredEntriesNothingCanRederive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	sink := &keyRecordingSink{}
	ob, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	id, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "10"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	stats, err := ob.Compact(func(string) bool { return false })
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if !stats.Rewritten || stats.EntriesDropped() != 1 {
		t.Fatalf("stats = %+v, want one entry dropped", stats)
	}
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// The boot after a compaction is the only place the reclaim is visible as
	// something other than a file size.
	reopened, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if _, ok := reopened.Entry(id); ok {
		t.Fatalf("entry %q still replays after compaction dropped it", id)
	}
}

// provenance: derived
// verifies: the RETAIN guard at this layer, keyed on IDENTITY. store.Journal
// mints an opaque entry id and a SEPARATE idempotency key, and the boot
// rebuild matches on the key -- so a guard that answered about entry ids would
// retain nothing at all here, silently, and republish the delivered history on
// every boot.
func TestOutbox_Compact_RetainIsAskedAboutTheIdentityNotTheEntryID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	sink := &keyRecordingSink{}
	ob, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	keptID, err := ob.JournalDerived("ev-1#0", domain.EffectDeposited{EventID: "ev-1", Amount: "10"})
	if err != nil {
		t.Fatalf("JournalDerived: %v", err)
	}
	if err := ob.Publish(context.Background(), keptID); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	// The entry id is NOT the identity: proving that is what makes the
	// assertion below about the mapping rather than about a coincidence.
	if keptID == "ev-1#0" {
		t.Fatalf("this service mints opaque entry ids; got %q which IS the identity, so this test proves nothing", keptID)
	}

	var asked []string
	if _, err := ob.Compact(func(identity string) bool {
		asked = append(asked, identity)
		return identity == "ev-1#0"
	}); err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if len(asked) != 1 || asked[0] != "ev-1#0" {
		t.Fatalf("retain was asked about %v, want the IDENTITY [ev-1#0]", asked)
	}
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if !reopened.KnowsIdentity("ev-1#0") {
		t.Fatalf("the retained identity is gone from the watermark -- the next boot would re-journal and re-deliver it")
	}
}

// provenance: derived
// verifies: pending work is never compacted away, whichever non-terminal shape
// it is in. This is the difference between reclaiming disk and destroying an
// effect that was committed to state and never delivered.
func TestOutbox_Compact_NeverDropsPendingWork(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	sink := &keyRecordingSink{fail: true}
	ob, err := OpenDurable(path, sink, testIDs(), 2)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	intentOnly, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	failedID, err := ob.Journal(domain.EffectWithdrawn{EventID: "w1", Amount: "2"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), failedID); err == nil {
		t.Fatalf("Publish against a failing sink returned nil")
	}

	if _, err := ob.Compact(func(string) bool { return false }); err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := OpenDurable(path, sink, testIDs(), 2)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	for _, id := range []string{intentOnly, failedID} {
		if _, ok := reopened.Entry(id); !ok {
			t.Errorf("undelivered entry %q did not survive compaction -- the effect is lost, not reclaimed", id)
		}
	}
	if got := len(reopened.Pending()); got != 2 {
		t.Errorf("pending after compaction = %d, want 2", got)
	}
}

// provenance: derived
// verifies: CompactionStats accumulates across runs and reports zero for a
// NON-DURABLE outbox rather than erroring. Both halves matter: the counters
// are the only evidence the mechanism is still working, and a caller must not
// have to know which constructor built the outbox it was handed.
func TestOutbox_CompactionStats_AccumulateAndTolerateTheNonDurableForm(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	sink := &keyRecordingSink{}
	ob, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	defer func() { _ = ob.Close() }()

	if runs, dropped, bytes := ob.CompactionStats(); runs != 0 || dropped != 0 || bytes != 0 {
		t.Fatalf("fresh outbox reports %d/%d/%d, want zeroes", runs, dropped, bytes)
	}
	for i := 0; i < 2; i++ {
		id, err := ob.Journal(domain.EffectDeposited{EventID: "d", Amount: "1"})
		if err != nil {
			t.Fatalf("Journal: %v", err)
		}
		if err := ob.Publish(context.Background(), id); err != nil {
			t.Fatalf("Publish: %v", err)
		}
		if _, err := ob.Compact(func(string) bool { return false }); err != nil {
			t.Fatalf("Compact: %v", err)
		}
	}
	runs, dropped, bytes := ob.CompactionStats()
	if runs != 2 {
		t.Errorf("runs = %d, want 2 -- a run that reclaimed nothing still ran", runs)
	}
	if dropped != 2 {
		t.Errorf("entriesDropped = %d, want 2", dropped)
	}
	if bytes <= 0 {
		t.Errorf("bytesReclaimed = %d, want > 0", bytes)
	}

	mem := NewOutbox(sink, testIDs(), 3)
	stats, err := mem.Compact(func(string) bool { return false })
	if err != nil {
		t.Fatalf("Compact on a non-durable outbox: %v", err)
	}
	if stats.Rewritten {
		t.Errorf("a non-durable outbox reported a rewrite")
	}
	if runs, _, _ := mem.CompactionStats(); runs != 0 {
		t.Errorf("non-durable outbox counted %d runs", runs)
	}
}

// provenance: derived
// verifies: the log stays APPENDABLE through a compaction that ran under a
// live outbox. After the rename the journal's descriptor points at an unlinked
// inode, so a later Journal would fsync into nowhere and report success -- a
// silent loss of exactly the intent the outbox exists to keep.
func TestOutbox_Compact_LaterJournalsStillReachTheDurableLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	sink := &keyRecordingSink{}
	ob, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	first, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), first); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if _, err := ob.Compact(func(string) bool { return false }); err != nil {
		t.Fatalf("Compact: %v", err)
	}

	after, err := ob.Journal(domain.EffectWithdrawn{EventID: "w1", Amount: "2"})
	if err != nil {
		t.Fatalf("Journal after compaction: %v", err)
	}
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if len(raw) == 0 {
		t.Fatalf("the durable log is EMPTY after a post-compaction journal")
	}
	reopened, err := OpenDurable(path, sink, testIDs(), 3)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if _, ok := reopened.Entry(after); !ok {
		t.Fatalf("the intent journaled after compaction is not in the log -- the handle was writing to an unlinked inode")
	}
}
