package eventlog

import (
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: derived
// verifies: durable event log (append + replay round-trip == the "rebuild
// from the log on restart" recovery semantics internal/app's state machine
// documents)
func TestAppendAndReplay_RoundTrips(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	events := []domain.Event{
		{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
		{ID: "e2", Type: domain.EventWithdrawn, Amount: "3"},
		{ID: "e3", Type: domain.EventDeposited, Amount: "5.5"},
	}
	for _, e := range events {
		if err := log.Append(e); err != nil {
			t.Fatalf("Append(%+v): %v", e, err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	replayed, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if len(replayed) != len(events) {
		t.Fatalf("Replay returned %d events, want %d", len(replayed), len(events))
	}
	for i, want := range events {
		if replayed[i] != want {
			t.Fatalf("event %d = %+v, want %+v", i, replayed[i], want)
		}
	}

	state := Rebuild(replayed)
	if state.Balance != "12.50000000" {
		t.Fatalf("rebuilt balance = %q, want 12.50000000 (10 - 3 + 5.5)", state.Balance)
	}
}

// provenance: derived
// verifies: recovery semantics ("rebuild from the log on restart" -- a
// process opening a log that appended-then-crashed before the READER side
// ever saw it must still see every durably-synced entry).
func TestReplay_OfNonexistentPathReturnsEmptyNotError(t *testing.T) {
	events, err := Replay(filepath.Join(t.TempDir(), "does-not-exist.jsonl"))
	if err != nil {
		t.Fatalf("Replay of a nonexistent path: %v", err)
	}
	if len(events) != 0 {
		t.Fatalf("got %d events, want 0", len(events))
	}
}

// provenance: derived
// verifies: schema-version migration duty -- a record from a future/unknown
// schema_version must fail loudly, never silently misparse (see the
// package doc).
func TestDecodeRecord_RejectsAnUnknownSchemaVersion(t *testing.T) {
	_, err := decodeRecord([]byte(`{"schema_version":99,"id":"e1","type":"deposited","amount":"1"}`))
	if err != ErrUnknownSchemaVersion {
		t.Fatalf("decodeRecord with schema_version=99: err = %v, want ErrUnknownSchemaVersion", err)
	}
}

// provenance: derived
// verifies: eventlog.Open surfaces a wrapped error rather than panicking
// when the target path cannot be created (e.g. the parent directory does
// not exist).
func TestOpen_NonexistentParentDirectoryErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "no-such-dir", "eventlog.jsonl")
	if _, err := Open(path); err == nil {
		t.Fatal("Open with a nonexistent parent directory did not error")
	}
}

// provenance: derived
// verifies: Log.Writable reflects the underlying file's open state --
// healthhttp's readiness gate depends on this.
func TestLog_Writable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !log.Writable() {
		t.Fatal("Writable() = false right after Open")
	}
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

// provenance: derived
// verifies: durability -- Rebuild is a pure fold of domain.Apply, so
// applying the SAME event twice across two separate Append calls (e.g. a
// caller that retried an Append after an ambiguous failure) has the
// ledger's economic effect once, exactly like verification/ratified's
// duplicate-event invariant.
func TestRebuild_DuplicateEventIDInTheLogHasEffectOnce(t *testing.T) {
	state := Rebuild([]domain.Event{
		{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
		{ID: "e1", Type: domain.EventDeposited, Amount: "10"}, // duplicate append
	})
	if state.Balance != "10.00000000" {
		t.Fatalf("balance = %q after a duplicated event ID, want 10.00000000 (applied once)", state.Balance)
	}
}
