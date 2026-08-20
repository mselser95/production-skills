package outboxlog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// seed writes one intent (plus any follow-on transitions) per entry and
// returns the open log, so each test states only what it is about.
func seed(t *testing.T, path string, recs ...Record) *Log {
	t.Helper()
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, rec := range recs {
		if err := log.Append(rec); err != nil {
			t.Fatalf("Append(%+v): %v", rec, err)
		}
	}
	return log
}

func intent(t *testing.T, id, key string) Record {
	t.Helper()
	env, err := EncodeEffect(domain.EffectDeposited{EventID: id, Amount: "10"})
	if err != nil {
		t.Fatalf("EncodeEffect: %v", err)
	}
	return Record{EntryID: id, State: StateIntent, IdempotencyKey: key, Effect: &env}
}

func statesByID(t *testing.T, path string) map[string]string {
	t.Helper()
	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	out := map[string]string{}
	for _, rec := range records {
		out[rec.EntryID] = rec.State
	}
	return out
}

// provenance: derived
// verifies: the liability outbox-log-grows-without-compaction -- a DELIVERED
// entry that nothing can re-derive is folded away, so the log tracks the live
// set rather than lifetime effect volume.
func TestCompact_DropsATerminalEntryNothingCanRederive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-done", "k-done"),
		Record{EntryID: "e-done", State: StateDelivered, IdempotencyKey: "k-done", Attempts: 1},
	)
	defer func() { _ = log.Close() }()

	stats, err := log.Compact(nil)
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if !stats.Rewritten {
		t.Fatalf("Rewritten = false; a delivered entry was there to drop")
	}
	if got := stats.EntriesDropped(); got != 1 {
		t.Fatalf("EntriesDropped = %d, want 1", got)
	}
	if states := statesByID(t, path); len(states) != 0 {
		t.Fatalf("log still holds %v -- a delivered, unre-derivable entry must not survive compaction", states)
	}
	if stats.BytesReclaimed() <= 0 {
		t.Fatalf("BytesReclaimed = %d, want > 0 -- the disk is the liability", stats.BytesReclaimed())
	}
}

// provenance: derived
// verifies: the half that makes compaction safe rather than destructive -- an
// entry that has NOT reached a terminal record survives, in every non-terminal
// shape it can be in. Dropping one of these is not a cleanup: it is the
// permanent loss of an effect that was committed to state and never delivered.
func TestCompact_KeepsEveryEntryThatIsNotTerminal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-pending", "k-pending"),
		intent(t, "e-failed", "k-failed"),
		Record{EntryID: "e-failed", State: StateFailed, IdempotencyKey: "k-failed", Attempts: 5},
		intent(t, "e-requeued", "k-requeued"),
		Record{EntryID: "e-requeued", State: StateDeadLettered, IdempotencyKey: "k-requeued"},
		// Requeue appends a fresh intent for the SAME id. Last transition
		// wins, so this entry is live again -- a rule that asked "did it EVER
		// reach a terminal state" would delete exactly what an operator just
		// asked to retry.
		Record{EntryID: "e-requeued", State: StateIntent, IdempotencyKey: "k-requeued"},
		// ... and one entry that IS terminal, so the assertion below is about
		// the retention rule rather than about compaction doing nothing.
		intent(t, "e-done", "k-done"),
		Record{EntryID: "e-done", State: StateDelivered, IdempotencyKey: "k-done"},
	)
	defer func() { _ = log.Close() }()

	if _, err := log.Compact(nil); err != nil {
		t.Fatalf("Compact: %v", err)
	}

	states := statesByID(t, path)
	for _, want := range []string{"e-pending", "e-failed", "e-requeued"} {
		if _, ok := states[want]; !ok {
			t.Errorf("%s is GONE after compaction -- an undelivered effect was destroyed, not reclaimed", want)
		}
	}
	if _, ok := states["e-done"]; ok {
		t.Errorf("e-done survived; the terminal entry nothing retains should have been folded away")
	}
	// The surviving entries must still REBUILD, which is the property that
	// says compaction kept whole entries rather than convenient records.
	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	snaps, err := Rebuild(records)
	if err != nil {
		t.Fatalf("Rebuild after compaction: %v -- compaction left the log unreplayable", err)
	}
	if len(snaps) != 3 {
		t.Fatalf("rebuilt %d entries, want 3", len(snaps))
	}
}

// provenance: derived
// verifies: the RETAIN guard. A delivered entry the caller says is still
// re-derivable must survive, because the log doubles as the delivery
// watermark: dropping it makes the next boot read the identity as unknown and
// re-journal it, republishing a delivered effect on EVERY boot.
func TestCompact_RetainKeepsAnEntryTheCallerCanStillRederive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-keep", "k-keep"),
		Record{EntryID: "e-keep", State: StateDelivered, IdempotencyKey: "k-keep"},
		intent(t, "e-drop", "k-drop"),
		Record{EntryID: "e-drop", State: StateDelivered, IdempotencyKey: "k-drop"},
	)
	defer func() { _ = log.Close() }()

	var sawKeys []string
	stats, err := log.Compact(func(entryID, key string) bool {
		sawKeys = append(sawKeys, entryID+"/"+key)
		return key == "k-keep"
	})
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if got := stats.EntriesDropped(); got != 1 {
		t.Fatalf("EntriesDropped = %d, want 1", got)
	}
	states := statesByID(t, path)
	if _, ok := states["e-keep"]; !ok {
		t.Fatalf("the retained entry was dropped -- the next boot would re-journal and republish it")
	}
	if _, ok := states["e-drop"]; ok {
		t.Fatalf("e-drop survived a retain that declined it")
	}
	// retain is asked about the entry id AND the idempotency key: the boot
	// rebuild matches on the key, so a guard that only ever saw entry ids
	// could not answer at all in this service.
	if len(sawKeys) != 2 || !strings.Contains(strings.Join(sawKeys, ","), "e-keep/k-keep") {
		t.Fatalf("retain saw %v, want both keys carried through", sawKeys)
	}
}

// provenance: derived
// verifies: nothing to drop => NO rewrite. A healthy boot must not spend an
// fsync and a rename producing a byte-identical copy, and must not widen the
// window a crash can land in for zero reclaim.
func TestCompact_DoesNotRewriteWhenThereIsNothingToDrop(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path, intent(t, "e-pending", "k-pending"))
	defer func() { _ = log.Close() }()

	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	modBefore := fi.ModTime()

	stats, err := log.Compact(nil)
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if stats.Rewritten {
		t.Fatalf("Rewritten = true with nothing terminal in the log")
	}
	if stats.BytesReclaimed() != 0 {
		t.Fatalf("BytesReclaimed = %d, want 0", stats.BytesReclaimed())
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("the log was rewritten anyway")
	}
	fi, err = os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if !fi.ModTime().Equal(modBefore) {
		t.Fatalf("mtime moved from %v to %v -- the file was replaced for no reclaim", modBefore, fi.ModTime())
	}
}

// provenance: derived
// verifies: the log stays APPENDABLE across a compaction. After the rename the
// original descriptor points at an unlinked inode, so an Append through it
// would write, fsync, return nil -- and vanish. That is a silent loss of
// exactly the journaled intents this package exists to keep, and it is
// invisible to every test that only reads the file back before appending.
func TestCompact_LaterAppendsStillReachTheLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-done", "k-done"),
		Record{EntryID: "e-done", State: StateDelivered, IdempotencyKey: "k-done"},
	)
	defer func() { _ = log.Close() }()

	if _, err := log.Compact(nil); err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if !log.Writable() {
		t.Fatalf("Writable() = false after a successful compaction")
	}
	if err := log.Append(intent(t, "e-after", "k-after")); err != nil {
		t.Fatalf("Append after compaction: %v", err)
	}

	states := statesByID(t, path)
	if _, ok := states["e-after"]; !ok {
		t.Fatalf("the post-compaction append is not in the log (%v) -- the handle is writing to an unlinked inode", states)
	}
}

// provenance: derived
// verifies: a compaction that cannot READ the log must abort with the log
// untouched. Treating an unreadable log as "no records" would rewrite it
// EMPTY, which is the most destructive thing this package can do and is
// reachable by the most ordinary of causes (a truncated write, a bad disk).
func TestCompact_RefusesToRewriteALogItCannotRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-done", "k-done"),
		Record{EntryID: "e-done", State: StateDelivered, IdempotencyKey: "k-done"},
	)
	defer func() { _ = log.Close() }()
	// A line no decoder will accept, appended behind the log's back.
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := f.WriteString("{not json\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	_ = f.Close()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if _, err := log.Compact(nil); err == nil {
		t.Fatalf("Compact returned nil on an unreadable log")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("the log changed after a failed compaction:\nbefore %q\nafter  %q", before, after)
	}
	if _, err := os.Stat(path + ".compact"); err == nil {
		t.Fatalf("the half-built replacement was left behind; the next boot would find a stray .compact file")
	}
}

// provenance: derived
// verifies: a compaction whose REPLACEMENT cannot be written never renames
// over the log. The original file stays complete and authoritative -- a failed
// reclaim costs disk, never history.
func TestCompact_AFailedRewriteIsNeverRenamedOverTheLog(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "outbox.jsonl")
	log := seed(t, path,
		intent(t, "e-done", "k-done"),
		Record{EntryID: "e-done", State: StateDelivered, IdempotencyKey: "k-done"},
		intent(t, "e-pending", "k-pending"),
	)
	defer func() { _ = log.Close() }()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	// Park a READ-ONLY, EMPTY file on the replacement path. writeReplacement's
	// O_WRONLY open fails on it, so not one record is written -- and, unlike a
	// directory in the way, a rename of this file over the log WOULD SUCCEED
	// and would leave an empty log behind. That is the whole point: the test
	// must be able to observe the destruction it forbids. Blocking the path
	// with something un-renameable made this test pass even when the error was
	// ignored and the rename attempted, because the rename then failed on its
	// own -- measured 2026-08-19, and the reason this shape replaced it.
	if os.Geteuid() == 0 {
		t.Skip("running as root: a 0444 file is still writable, so this test could not fail")
	}
	if err := os.WriteFile(path+".compact", nil, 0o444); err != nil {
		t.Fatalf("seed the unwritable replacement: %v", err)
	}

	if _, err := log.Compact(nil); err == nil {
		t.Fatalf("Compact returned nil though the replacement could not be written")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v -- the log itself is gone after a failed compaction", err)
	}
	if len(after) == 0 {
		t.Fatalf("the log is EMPTY -- a replacement that was never written got renamed over the only copy of history")
	}
	if string(before) != string(after) {
		t.Fatalf("the log was modified by a compaction that failed:\nbefore %q\nafter  %q", before, after)
	}
	// And the entries are all still replayable, which is the property an
	// operator actually depends on.
	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if _, err := Rebuild(records); err != nil {
		t.Fatalf("Rebuild: %v", err)
	}
}
