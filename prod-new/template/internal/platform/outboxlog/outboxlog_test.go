package outboxlog

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: derived
// verifies: durable outbox journal -- append + replay round-trips, and
// folding the transitions reconstructs each entry's current state.
func TestAppendReplayAndRebuild_RoundTrips(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")
	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	env, err := EncodeEffect(domain.EffectDeposited{EventID: "d1", Amount: "10"})
	if err != nil {
		t.Fatalf("EncodeEffect: %v", err)
	}
	for _, rec := range []Record{
		{EntryID: "e-1", State: StateIntent, IdempotencyKey: "k-1", Effect: &env},
		{EntryID: "e-1", State: StateFailed, IdempotencyKey: "k-1", Attempts: 3},
		{EntryID: "e-1", State: StateDelivered, IdempotencyKey: "k-1", Attempts: 4},
	} {
		if err := log.Append(rec); err != nil {
			t.Fatalf("Append(%+v): %v", rec, err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if len(records) != 3 {
		t.Fatalf("replayed %d records, want 3", len(records))
	}

	snapshots, err := Rebuild(records)
	if err != nil {
		t.Fatalf("Rebuild: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("rebuilt %d entries, want 1", len(snapshots))
	}
	got := snapshots[0]
	if got.State != StateDelivered {
		t.Errorf("state = %q, want the LAST transition's %q", got.State, StateDelivered)
	}
	if got.Attempts != 4 {
		t.Errorf("attempts = %d, want 4", got.Attempts)
	}
	if got.IdempotencyKey != "k-1" {
		t.Errorf("key = %q, want k-1", got.IdempotencyKey)
	}
	if got.Effect != (domain.EffectDeposited{EventID: "d1", Amount: "10"}) {
		t.Errorf("effect = %#v, want the deposited effect from the intent record", got.Effect)
	}
}

// provenance: derived
// verifies: the durable format REFUSES an effect it cannot represent, rather
// than writing a record that replays into something else.
func TestEncodeEffect_RefusesAnUnencodableEffect(t *testing.T) {
	_, err := EncodeEffect(domain.EffectWithdrawalRejected{EventID: "x"})
	if !errors.Is(err, ErrUnencodableEffect) {
		t.Fatalf("EncodeEffect of a non-routable effect = %v, want ErrUnencodableEffect", err)
	}
}

// provenance: derived
// verifies: schema-version migration duty -- a record from an unknown
// schema_version fails loudly rather than silently misparsing.
func TestDecodeRecord_RejectsAnUnknownSchemaVersion(t *testing.T) {
	_, err := DecodeRecord([]byte(`{"schema_version":99,"entry_id":"e1","state":"intent"}`))
	if !errors.Is(err, ErrUnknownSchemaVersion) {
		t.Fatalf("err = %v, want ErrUnknownSchemaVersion", err)
	}
}

// provenance: derived
// verifies: a malformed record is rejected, never coerced into a plausible
// zero-valued entry.
func TestDecodeRecord_RejectsMalformedRecords(t *testing.T) {
	for _, line := range []string{
		`{"schema_version":1,"state":"intent"}`,                     // no entry_id
		`{"schema_version":1,"entry_id":"e1","state":"teleported"}`, // unknown state
		`{"schema_version":1,"entry_id":"e1"}`,                      // no state
		`not json`,
		`[]`,
	} {
		if _, err := DecodeRecord([]byte(line)); err == nil {
			t.Errorf("DecodeRecord(%s) accepted a malformed record", line)
		}
	}
}

// provenance: derived
// verifies: a transition for an entry whose intent was never recorded is an
// ERROR. Silently inventing the entry would hide a truncated log, and the
// truncation is exactly the case where an effect is at risk.
func TestRebuild_RefusesATransitionWithNoIntent(t *testing.T) {
	_, err := Rebuild([]Record{{EntryID: "e-1", State: StateDelivered}})
	if err == nil {
		t.Fatal("Rebuild accepted a delivered transition with no recorded intent")
	}
}

// provenance: derived
// verifies: compatibility (tier-policy: compatibility.schema =
// expand_contract, breaking_check required) -- a GOLDEN fixture of the
// on-disk format, so renaming a field or an effect-kind tag is caught here
// instead of silently changing what an already-written outbox replays into.
func TestOutboxlog_GoldenRecordFormatIsStillReadable(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "golden_v1.jsonl"))
	if err != nil {
		t.Fatalf("read golden fixture: %v", err)
	}
	path := filepath.Join(t.TempDir(), "replay.jsonl")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write temp copy: %v", err)
	}
	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay(golden): %v", err)
	}
	snapshots, err := Rebuild(records)
	if err != nil {
		t.Fatalf("Rebuild(golden): %v", err)
	}
	if len(snapshots) != 2 {
		t.Fatalf("golden rebuilt %d entries, want 2", len(snapshots))
	}
	if snapshots[0].State != StateDelivered || snapshots[0].Attempts != 2 {
		t.Errorf("entry 0 = %+v, want delivered with 2 attempts", snapshots[0])
	}
	if snapshots[1].State != StateIntent {
		t.Errorf("entry 1 state = %q, want intent (still pending)", snapshots[1].State)
	}
	if snapshots[1].Effect != (domain.EffectWithdrawn{EventID: "w1", Amount: "3"}) {
		t.Errorf("entry 1 effect = %#v -- the wire format has drifted from schema_version 1",
			snapshots[1].Effect)
	}
	// A schema-1 record carries no journaling time, and the rebuild must say
	// so rather than reporting a zero that reads as "journaled at the epoch"
	// or, worse, as "brand new".
	for i, snap := range snapshots {
		if snap.AgeKnown {
			t.Errorf("golden v1 entry %d reports AgeKnown -- a record written before the "+
				"timestamp existed cannot have a known age", i)
		}
	}
}

// provenance: derived
// verifies: compatibility -- the CURRENT schema round-trips, including the
// dead-letter transition and the journaling timestamp that schema 1 lacked.
//
// This fixture exists beside golden_v1.jsonl rather than replacing it. The
// v1 file is evidence of what the format used to be; editing it to make a
// test pass would erase the only proof that a build claiming to read v1 can
// actually do so.
func TestOutboxlog_GoldenV2RecordFormatRoundTrips(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "golden_v2.jsonl"))
	if err != nil {
		t.Fatalf("read golden v2 fixture: %v", err)
	}
	path := filepath.Join(t.TempDir(), "replay_v2.jsonl")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write temp copy: %v", err)
	}
	records, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay(golden v2): %v", err)
	}
	snapshots, err := Rebuild(records)
	if err != nil {
		t.Fatalf("Rebuild(golden v2): %v", err)
	}
	if len(snapshots) != 3 {
		t.Fatalf("golden v2 rebuilt %d entries, want 3", len(snapshots))
	}

	byID := map[string]Snapshot{}
	for _, s := range snapshots {
		byID[s.EntryID] = s
	}
	if got := byID["e-2"]; !got.AgeKnown || got.JournaledAtUnixNano != 1750000001000000000 {
		t.Errorf("e-2 = %+v, want a KNOWN journaling time -- the timestamp did not survive the round trip", got)
	}
	if got := byID["e-3"].State; got != StateDeadLettered {
		t.Errorf("e-3 state = %q, want %q -- a dead-lettered entry must replay as dead-lettered, "+
			"or a restart resurrects work a bound deliberately retired", got, StateDeadLettered)
	}
}
