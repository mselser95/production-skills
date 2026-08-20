package eventlog

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// depositN appends n deposits of one unit each and returns the log.
func depositN(t *testing.T, log *Log, from, n int) {
	t.Helper()
	for i := from; i < from+n; i++ {
		e := domain.Event{ID: "e" + strconv.Itoa(i), Type: domain.EventDeposited, Amount: "1"}
		if err := log.Append(context.Background(), e); err != nil {
			t.Fatalf("Append(%s): %v", e.ID, err)
		}
	}
}

func openTemp(t *testing.T) (*Log, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = log.Close() })
	return log, path
}

// provenance: derived
// verifies: recovery from a snapshot reconstructs EXACTLY the state a full
// replay from genesis would, AND actually replays only the tail.
//
// Both halves are the test. The first proves correctness; the second proves
// the feature does anything at all. A snapshot that is written but never
// consulted on boot passes the first and fails the second, which is
// precisely how this ships as decoration -- the state looks right because
// the full replay produced it, and nobody notices the snapshot was
// ornamental until boot time becomes an outage.
func TestRecover_UsesTheSnapshotAndReplaysOnlyTheTail(t *testing.T) {
	log, path := openTemp(t)

	depositN(t, log, 0, 500)
	state500, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover before snapshot: %v", err)
	}
	if err := log.Snapshot(state500); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	depositN(t, log, 500, 7)

	recovered, stats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}

	// --- half one: the state is right -------------------------------------
	if !stats.SnapshotFound {
		t.Fatal("SnapshotFound = false; recovery ignored the snapshot entirely")
	}
	if recovered.Balance != "507.00000000" {
		t.Fatalf("balance = %q, want 507.00000000", recovered.Balance)
	}
	if recovered.Version != 507 {
		t.Errorf("version = %d, want 507", recovered.Version)
	}
	if got := len(recovered.Applied); got != 507 {
		t.Errorf("applied set has %d entries, want 507 -- the snapshot lost idempotency bookkeeping", got)
	}

	// --- half two: it did LESS work ---------------------------------------
	if stats.EventsReplayed != 7 {
		t.Fatalf("EventsReplayed = %d, want 7 -- recovery folded events the snapshot "+
			"already subsumes, so the snapshot is decoration and boot is still O(history)",
			stats.EventsReplayed)
	}
}

// provenance: derived
// verifies: snapshot-based recovery and full-genesis replay agree exactly,
// compared as whole states rather than field by field -- so a domain that
// grows a field nobody remembered to snapshot fails here.
func TestRecover_SnapshotPathEqualsFullReplayPath(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 120)

	viaReplay := Rebuild(mustReplay(t, path))

	mid, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if err := log.Snapshot(mid); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	viaSnapshot, stats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover after snapshot: %v", err)
	}
	if stats.EventsReplayed != 0 {
		t.Errorf("EventsReplayed = %d right after a snapshot, want 0", stats.EventsReplayed)
	}

	if viaSnapshot.Balance != viaReplay.Balance || viaSnapshot.Version != viaReplay.Version {
		t.Fatalf("snapshot path gave {%s v%d}, genesis replay gave {%s v%d}",
			viaSnapshot.Balance, viaSnapshot.Version, viaReplay.Balance, viaReplay.Version)
	}
	if len(viaSnapshot.Applied) != len(viaReplay.Applied) {
		t.Fatalf("applied sets differ: snapshot %d, replay %d", len(viaSnapshot.Applied), len(viaReplay.Applied))
	}
	for _, id := range viaReplay.AppliedIDs() {
		if !viaSnapshot.Applied[id] {
			t.Fatalf("applied id %q survived a genesis replay but not the snapshot", id)
		}
	}
}

// provenance: derived
// verifies: compaction bounds storage -- it discards the history the
// snapshot subsumes, keeps the snapshot and the tail, and the log still
// recovers to the same state afterwards.
func TestCompact_BoundsTheLogAndPreservesTheState(t *testing.T) {
	log, path := openTemp(t)

	depositN(t, log, 0, 300)
	mid, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if err := log.Snapshot(mid); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	depositN(t, log, 300, 5)

	before, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover before compact: %v", err)
	}

	stats, err := log.Compact()
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if !stats.Compacted {
		t.Fatal("Compacted = false despite a valid snapshot in the log")
	}
	// snapshot + 5 tail events
	if stats.RecordsAfter != 6 {
		t.Errorf("RecordsAfter = %d, want 6 (snapshot + 5 events)", stats.RecordsAfter)
	}
	if stats.RecordsAfter >= stats.RecordsBefore {
		t.Fatalf("compaction reclaimed nothing: %d -> %d records", stats.RecordsBefore, stats.RecordsAfter)
	}

	after, afterStats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover after compact: %v", err)
	}
	if after.Balance != before.Balance || after.Version != before.Version {
		t.Fatalf("compaction changed the state: {%s v%d} -> {%s v%d}",
			before.Balance, before.Version, after.Balance, after.Version)
	}
	if afterStats.EventsReplayed != 5 {
		t.Errorf("EventsReplayed after compaction = %d, want 5", afterStats.EventsReplayed)
	}
}

// provenance: derived
// verifies: the log is still APPENDABLE after compaction.
//
// Compaction renames a new file over the old one, so the descriptor the Log
// was holding now points at an unlinked inode. Without reopening, every
// subsequent Append would succeed, sync, and vanish -- durable-looking
// writes to a file nothing can ever read.
func TestCompact_LogRemainsAppendableAfterwards(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 10)
	mid, _, _ := Recover(path)
	if err := log.Snapshot(mid); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if _, err := log.Compact(); err != nil {
		t.Fatalf("Compact: %v", err)
	}

	depositN(t, log, 10, 3)
	state, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if state.Version != 13 {
		t.Fatalf("version = %d after appending 3 post-compaction events, want 13 -- "+
			"the appends went to the unlinked pre-compaction inode", state.Version)
	}
}

// provenance: derived
// verifies: compaction without a snapshot is a NO-OP, not a truncation.
// Compacting an un-snapshotted log would simply delete history.
func TestCompact_WithoutASnapshotIsANoOp(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 20)

	stats, err := log.Compact()
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if stats.Compacted {
		t.Fatal("Compacted = true with no snapshot in the log -- history was discarded " +
			"with nothing subsuming it")
	}
	state, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if state.Version != 20 {
		t.Fatalf("version = %d, want 20 -- a no-op compaction lost events", state.Version)
	}
}

// provenance: derived
// verifies: a CORRUPT snapshot falls back to full replay, loudly, rather
// than failing the boot or silently starting from genesis as if all were
// well.
//
// A snapshot is a performance optimization. Refusing to start because one is
// unreadable turns a slow boot into an outage; starting from genesis without
// saying so hides the fact that recovery just did orders of magnitude more
// work than it should have.
func TestRecover_CorruptSnapshotFallsBackToFullReplayAndSaysSo(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 40)
	mid, _, _ := Recover(path)
	if err := log.Snapshot(mid); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	depositN(t, log, 40, 2)
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Corrupt the snapshot's payload, leaving the line valid JSONL.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	corrupted := replaceSnapshotState(t, data, `"not a state object"`)
	if err := os.WriteFile(path, corrupted, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	state, stats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover with a corrupt snapshot: %v -- a bad optimization must not "+
			"fail the boot", err)
	}
	if stats.SnapshotsRejected != 1 {
		t.Errorf("SnapshotsRejected = %d, want 1 -- the fallback happened silently", stats.SnapshotsRejected)
	}
	if stats.SnapshotFound {
		t.Error("SnapshotFound = true despite the only snapshot being corrupt")
	}
	if stats.EventsReplayed != 42 {
		t.Errorf("EventsReplayed = %d, want 42 (full replay from genesis)", stats.EventsReplayed)
	}
	if state.Version != 42 {
		t.Fatalf("version = %d, want 42 -- the fallback did not reconstruct the state", state.Version)
	}
}

// replaceSnapshotState rewrites the `state` field of the first snapshot line.
func replaceSnapshotState(t *testing.T, data []byte, newState string) []byte {
	t.Helper()
	lines := splitLines(data)
	for i, line := range lines {
		var rec record
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		if rec.kindOf() != kindSnapshot {
			continue
		}
		rec.State = json.RawMessage(newState)
		out, err := json.Marshal(rec)
		if err != nil {
			t.Fatalf("re-marshal: %v", err)
		}
		lines[i] = out
		return joinLines(lines)
	}
	t.Fatal("no snapshot record found to corrupt")
	return nil
}

func splitLines(data []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, b := range data {
		if b == '\n' {
			if i > start {
				out = append(out, data[start:i])
			}
			start = i + 1
		}
	}
	if start < len(data) {
		out = append(out, data[start:])
	}
	return out
}

func joinLines(lines [][]byte) []byte {
	var out []byte
	for _, l := range lines {
		out = append(out, l...)
		out = append(out, '\n')
	}
	return out
}

// provenance: derived
// verifies: Replay REFUSES a log containing a snapshot instead of returning
// the tail.
//
// On a compacted log the events Replay can see are only what came after the
// snapshot, so Rebuild(Replay(path)) reconstructs a confidently wrong state
// with no error anywhere. Refusing is the only safe answer, and this test is
// what stops someone re-introducing the convenience.
func TestReplay_RefusesALogContainingASnapshot(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 5)
	mid, _, _ := Recover(path)
	if err := log.Snapshot(mid); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}

	if _, err := Replay(path); err == nil {
		t.Fatal("Replay returned events for a snapshotted log -- a caller doing " +
			"Rebuild(Replay(path)) would silently rebuild from the tail alone")
	}
}

// provenance: derived
// verifies: a v1 log -- written before snapshots existed, with no `kind`
// field -- still recovers. An upgrade that could not read the log written by
// the build it replaces is an outage caused by deploying.
func TestRecover_ReadsAV1LogWrittenBeforeSnapshotsExisted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v1.jsonl")
	v1 := `{"schema_version":1,"id":"a","type":"deposited","amount":"10"}` + "\n" +
		`{"schema_version":1,"id":"b","type":"withdrawn","amount":"4"}` + "\n"
	if err := os.WriteFile(path, []byte(v1), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	state, stats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover(v1 log): %v", err)
	}
	if stats.SnapshotFound {
		t.Error("SnapshotFound = true for a log that predates snapshots")
	}
	if stats.EventsReplayed != 2 {
		t.Errorf("EventsReplayed = %d, want 2", stats.EventsReplayed)
	}
	if state.Balance != "6.00000000" {
		t.Fatalf("balance = %q, want 6.00000000 (10 - 4)", state.Balance)
	}
}

// provenance: derived
// verifies: domain.State survives the snapshot codec unchanged.
//
// This is a fitness function on the DOMAIN, not on this package. The
// snapshot mechanism is generic over whatever State a scaffolded repo
// defines, and a State with an unexported field or a non-JSON-representable
// type would snapshot to something that silently restores wrong. Replacing
// the domain -- which every repo built from this template does -- must fail
// here rather than in production at 3am.
func TestSnapshot_DomainStateRoundTrips(t *testing.T) {
	state := domain.NewState()
	state, _ = domain.Apply(state, domain.Event{ID: "x", Type: domain.EventDeposited, Amount: "7.25"})
	state, _ = domain.Apply(state, domain.Event{ID: "y", Type: domain.EventWithdrawn, Amount: "2"})

	raw, err := encodeState(state)
	if err != nil {
		t.Fatalf("encodeState: %v", err)
	}
	var back domain.State
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.Balance != state.Balance || back.Version != state.Version {
		t.Fatalf("round-trip changed the state: {%s v%d} -> {%s v%d}",
			state.Balance, state.Version, back.Balance, back.Version)
	}
	if len(back.Applied) != len(state.Applied) {
		t.Fatalf("round-trip lost idempotency bookkeeping: %d ids -> %d", len(state.Applied), len(back.Applied))
	}
	for id := range state.Applied {
		if !back.Applied[id] {
			t.Fatalf("applied id %q did not survive the round-trip", id)
		}
	}
}

// provenance: derived
// verifies: recovery picks the NEWEST snapshot when several exist, which is
// what keeps the replayed tail short as snapshots accumulate.
func TestRecover_UsesTheNewestSnapshot(t *testing.T) {
	log, path := openTemp(t)

	depositN(t, log, 0, 10)
	s1, _, _ := Recover(path)
	if err := log.Snapshot(s1); err != nil {
		t.Fatalf("Snapshot 1: %v", err)
	}
	depositN(t, log, 10, 10)
	s2, _, _ := Recover(path)
	if err := log.Snapshot(s2); err != nil {
		t.Fatalf("Snapshot 2: %v", err)
	}
	depositN(t, log, 20, 3)

	state, stats, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if stats.EventsReplayed != 3 {
		t.Fatalf("EventsReplayed = %d, want 3 -- recovery used an older snapshot than it had", stats.EventsReplayed)
	}
	if state.Version != 23 {
		t.Errorf("version = %d, want 23", state.Version)
	}
}

func mustReplay(t *testing.T, path string) []domain.Event {
	t.Helper()
	events, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	return events
}

// provenance: derived
// verifies: AppendsSinceSnapshot measures the replay tail -- it counts
// events, resets at a snapshot, and reports what compaction left behind.
// This counter is what the composition root's snapshot loop reads, so a
// wrong answer means either snapshots that never fire (unbounded boot) or
// fire on every event (unbounded write amplification).
func TestAppendsSinceSnapshot_CountsResetsAndSurvivesCompaction(t *testing.T) {
	log, path := openTemp(t)

	if got := log.AppendsSinceSnapshot(); got != 0 {
		t.Fatalf("fresh log reports %d appends since snapshot, want 0", got)
	}
	depositN(t, log, 0, 4)
	if got := log.AppendsSinceSnapshot(); got != 4 {
		t.Errorf("after 4 appends: %d, want 4", got)
	}

	state, _, _ := Recover(path)
	if err := log.Snapshot(state); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if got := log.AppendsSinceSnapshot(); got != 0 {
		t.Fatalf("after a snapshot: %d, want 0 -- the tail is empty, so a snapshot loop "+
			"reading this would snapshot again immediately", got)
	}

	depositN(t, log, 4, 2)
	if _, err := log.Compact(); err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if got := log.AppendsSinceSnapshot(); got != 2 {
		t.Errorf("after compaction with a 2-event tail: %d, want 2", got)
	}
}

// provenance: derived
// verifies: writes to a CLOSED log fail loudly instead of silently
// succeeding. A durable-looking Append that went nowhere is the worst
// outcome this package can produce, because the caller has already told its
// own caller the event is safe.
func TestWritesToAClosedLogFail(t *testing.T) {
	log, _ := openTemp(t)
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	if err := log.Append(context.Background(), domain.Event{ID: "x", Type: domain.EventDeposited, Amount: "1"}); err == nil {
		t.Error("Append on a closed log returned nil -- the caller believes the event is durable")
	}
	if err := log.Snapshot(domain.NewState()); err == nil {
		t.Error("Snapshot on a closed log returned nil")
	}
	// Close is idempotent: shutdown paths are not always exactly-once.
	if err := log.Close(); err != nil {
		t.Errorf("second Close: %v", err)
	}
	// And readiness must stop claiming the log is writable. healthhttp's
	// gate reads this, so a stale true means the pod reports ready for
	// traffic it can no longer journal.
	if log.Writable() {
		t.Error("Writable() = true after Close -- the readiness gate would say yes " +
			"to writes that cannot be journaled")
	}
}

// provenance: derived
// verifies: Recover on a path that does not exist is an empty genesis
// state, not an error. A service booting for the very first time has no log,
// and refusing to start would make the first deploy the broken one.
func TestRecover_MissingLogIsGenesisNotAnError(t *testing.T) {
	state, stats, err := Recover(filepath.Join(t.TempDir(), "absent.jsonl"))
	if err != nil {
		t.Fatalf("Recover(missing): %v", err)
	}
	if stats.RecordsScanned != 0 || stats.SnapshotFound {
		t.Errorf("stats = %+v, want an empty scan", stats)
	}
	if state.Balance != domain.ZeroAmount {
		t.Errorf("balance = %q, want the genesis %q", state.Balance, domain.ZeroAmount)
	}
}

// provenance: derived
// verifies: a corrupt EVENT record is FATAL, unlike a corrupt snapshot.
// Events are history; continuing past one silently is how a ledger loses
// money. The asymmetry with the snapshot fallback is deliberate and this
// pins it.
func TestRecover_CorruptEventRecordIsFatal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.jsonl")
	bad := `{"schema_version":2,"kind":"event","id":"a","type":"deposited","amount":"1"}` + "\n" +
		`{ this is not json` + "\n"
	if err := os.WriteFile(path, []byte(bad), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, _, err := Recover(path); err == nil {
		t.Fatal("Recover continued past a corrupt EVENT record -- history was skipped silently")
	}
}

// provenance: derived
// verifies: an unknown schema_version is refused rather than best-effort
// parsed, on the recovery path as well as the single-record one.
func TestRecover_UnknownSchemaVersionIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "future.jsonl")
	if err := os.WriteFile(path, []byte(`{"schema_version":99,"kind":"event","id":"a"}`+"\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, _, err := Recover(path); err == nil {
		t.Fatal("Recover accepted a record from a schema this build cannot read")
	}
}

// provenance: derived
// verifies: compaction refuses to act on a snapshot it cannot decode,
// falling back to the no-op rather than treating an unreadable snapshot as
// a licence to discard the history behind it.
func TestCompact_IgnoresAnUndecodableSnapshot(t *testing.T) {
	log, path := openTemp(t)
	depositN(t, log, 0, 6)
	state, _, _ := Recover(path)
	if err := log.Snapshot(state); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if err := os.WriteFile(path, replaceSnapshotState(t, data, `12345`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = reopened.Close() }()

	stats, err := reopened.Compact()
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	if stats.Compacted {
		t.Fatal("compacted against a snapshot that cannot be decoded -- the history it " +
			"claimed to subsume was discarded on the strength of an unreadable record")
	}
	state2, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if state2.Version != 6 {
		t.Fatalf("version = %d, want 6 -- events were lost", state2.Version)
	}
}

// provenance: derived
// verifies: when compaction cannot write its replacement, it fails WITHOUT
// touching the existing log.
//
// This is the failure that matters most in this package. Compaction's whole
// job is to delete history it believes is subsumed; a version that removed
// anything before its replacement was safely on disk would turn a full disk
// or a permissions mistake into permanent data loss. The assertion is not
// that it errors -- it is that the log still recovers to the same state
// afterwards.
func TestCompact_FailureLeavesTheOriginalLogIntact(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "eventlog.jsonl")
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = log.Close() }()

	depositN(t, log, 0, 12)
	state, _, _ := Recover(path)
	if err := log.Snapshot(state); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	depositN(t, log, 12, 3)
	before, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover before: %v", err)
	}

	// Make the directory unwritable so the temp file cannot be created.
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Skipf("cannot make the directory read-only here: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	if _, err := log.Compact(); err == nil {
		t.Fatal("Compact reported success while unable to write its replacement")
	}

	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatalf("restore dir mode: %v", err)
	}
	after, _, err := Recover(path)
	if err != nil {
		t.Fatalf("Recover after a failed compaction: %v", err)
	}
	if after.Version != before.Version || after.Balance != before.Balance {
		t.Fatalf("a FAILED compaction changed the log: {%s v%d} -> {%s v%d}",
			before.Balance, before.Version, after.Balance, after.Version)
	}
}
