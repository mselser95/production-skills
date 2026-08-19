package eventlog

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// openTemp is shared with snapshot_test.go in this package.

// provenance: derived
// verifies: the tail surface -- positions are assigned 1..N in append order,
// with no holes, so a relay checkpoint is a total order over the log
func TestReadAfter_AssignsGaplessPositionsInAppendOrder(t *testing.T) {
	l, _ := openTemp(t)
	for i := 0; i < 4; i++ {
		if err := l.Append(domain.Event{ID: string(rune('a' + i)), Type: domain.EventDeposited, Amount: "1"}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	got, err := l.ReadAfter(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("read %d events, want 4", len(got))
	}
	for i, se := range got {
		if se.Seq != int64(i+1) {
			t.Fatalf("event %d has Seq %d, want %d (positions must be gapless)", i, se.Seq, i+1)
		}
		if se.Position() != se.Seq {
			t.Fatalf("Position() = %d, Seq = %d; they must be the same value", se.Position(), se.Seq)
		}
		if se.Event.ID != string(rune('a'+i)) {
			t.Fatalf("event %d id = %q, want %q (append order)", i, se.Event.ID, string(rune('a'+i)))
		}
	}
}

// provenance: derived
// verifies: ReadAfter is exclusive on `after` and honours `limit`, which is
// what lets a relay page through a long log without an unbounded read
func TestReadAfter_IsExclusiveAndBounded(t *testing.T) {
	l, _ := openTemp(t)
	for i := 0; i < 5; i++ {
		if err := l.Append(domain.Event{ID: string(rune('a' + i)), Type: domain.EventDeposited, Amount: "1"}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	got, err := l.ReadAfter(context.Background(), 2, 2)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(got) != 2 || got[0].Seq != 3 || got[1].Seq != 4 {
		t.Fatalf("ReadAfter(2, 2) = %+v, want positions 3 and 4", got)
	}
	// Past the head is empty, not an error: that is how a relay learns it is
	// caught up rather than that something broke.
	empty, err := l.ReadAfter(context.Background(), 99, 10)
	if err != nil {
		t.Fatalf("ReadAfter past the head: %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("ReadAfter past the head returned %d events, want 0", len(empty))
	}
}

// provenance: derived
// verifies: a non-positive limit is REFUSED rather than silently treated as
// unbounded (an unbounded read of a long log is an out-of-memory) or as zero
// (a relay that reads nothing forever, reporting success)
func TestReadAfter_RejectsNonPositiveLimit(t *testing.T) {
	l, _ := openTemp(t)
	for _, limit := range []int{0, -1} {
		if _, err := l.ReadAfter(context.Background(), 0, limit); err == nil {
			t.Errorf("ReadAfter with limit %d succeeded, want an error", limit)
		}
	}
}

// provenance: derived
// verifies: Head reports the highest committed position, and 0 on an empty
// log -- the denominator of the relay's lag signal
func TestHead_ReportsTheHighestPosition(t *testing.T) {
	l, _ := openTemp(t)
	head, err := l.Head(context.Background())
	if err != nil {
		t.Fatalf("Head on an empty log: %v", err)
	}
	if head != 0 {
		t.Fatalf("Head on an empty log = %d, want 0", head)
	}
	for i := 0; i < 3; i++ {
		if err := l.Append(domain.Event{ID: string(rune('a' + i)), Type: domain.EventDeposited, Amount: "1"}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	if head, err = l.Head(context.Background()); err != nil || head != 3 {
		t.Fatalf("Head = %d, %v; want 3, nil", head, err)
	}
}

// provenance: derived
// verifies: Head is recovered from an EXISTING file at open, so a restarted
// process does not restart positions at 1 and collide with events already on
// disk
func TestHead_SurvivesAReopen(t *testing.T) {
	l, path := openTemp(t)
	for i := 0; i < 3; i++ {
		if err := l.Append(domain.Event{ID: string(rune('a' + i)), Type: domain.EventDeposited, Amount: "1"}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	if err := l.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if head, err := reopened.Head(context.Background()); err != nil || head != 3 {
		t.Fatalf("Head after reopen = %d, %v; want 3, nil", head, err)
	}
	if err := reopened.Append(domain.Event{ID: "d", Type: domain.EventDeposited, Amount: "1"}); err != nil {
		t.Fatalf("Append after reopen: %v", err)
	}
	got, err := reopened.ReadAfter(context.Background(), 3, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(got) != 1 || got[0].Seq != 4 {
		t.Fatalf("post-reopen append landed at %+v, want a single event at position 4 -- "+
			"restarting positions at 1 would give two events the same relay position", got)
	}
}

// provenance: derived
// verifies: an ingested fact keeps BOTH positions -- the local one that
// orders it here, and the foreign one that identifies it upstream
//
// Collapsing the two loses one meaning each way: the foreign sequence is the
// deduplication and gap-detection key (a hole there is a fact not yet
// received, which cannot be invented), while the local sequence is simply the
// order this log observed things and never has holes.
func TestAppendIngested_KeepsBothPositions(t *testing.T) {
	l, _ := openTemp(t)
	if err := l.Append(domain.Event{ID: "own", Type: domain.EventDeposited, Amount: "1"}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := l.AppendIngested(domain.Event{ID: "up", Type: domain.EventDeposited, Amount: "2"}, 91); err != nil {
		t.Fatalf("AppendIngested: %v", err)
	}
	got, err := l.ReadAfter(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("read %d events, want 2", len(got))
	}
	if got[0].Origin != OriginRaised || got[0].ForeignSeq != 0 {
		t.Fatalf("raised event = %+v, want origin %q and no foreign position", got[0], OriginRaised)
	}
	if got[1].Origin != OriginIngested || got[1].ForeignSeq != 91 {
		t.Fatalf("ingested event = %+v, want origin %q and foreign position 91", got[1], OriginIngested)
	}
	// The local positions are consecutive across BOTH kinds: one log, one
	// order, one relay checkpoint. Two separate logs could not reproduce this
	// interleaving without recording the merge order somewhere -- which is a
	// single log with extra steps.
	if got[0].Seq != 1 || got[1].Seq != 2 {
		t.Fatalf("local positions = %d, %d; want 1, 2 interleaved in one order", got[0].Seq, got[1].Seq)
	}
}

// provenance: derived
// verifies: a record written before the Origin field existed reads as
// RAISED -- which is what it was, since ingestion did not exist yet
func TestOriginOf_PreV3RecordsReadAsRaised(t *testing.T) {
	var r record
	if got := r.originOf(); got != OriginRaised {
		t.Fatalf("originOf on a record with no origin = %q, want %q", got, OriginRaised)
	}
	r.Origin = OriginIngested
	if got := r.originOf(); got != OriginIngested {
		t.Fatalf("originOf = %q, want %q", got, OriginIngested)
	}
}

// provenance: derived
// verifies: pre-v3 records on disk (which carry no Seq) are still given
// gapless positions, so an upgrade does not make the existing log unreadable
// by the relay
func TestReadAfter_BackfillsPositionsForPreV3Records(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.jsonl")
	legacy := `{"schema_version":1,"id":"a","type":"deposited","amount":"1"}
{"schema_version":1,"id":"b","type":"withdrawn","amount":"1"}
`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	l, err := Open(path)
	if err != nil {
		t.Fatalf("Open a pre-v3 log: %v", err)
	}
	defer func() { _ = l.Close() }()

	got, err := l.ReadAfter(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(got) != 2 || got[0].Seq != 1 || got[1].Seq != 2 {
		t.Fatalf("pre-v3 records read as %+v, want positions 1 and 2", got)
	}
	if got[0].Origin != OriginRaised {
		t.Fatalf("pre-v3 record origin = %q, want %q", got[0].Origin, OriginRaised)
	}
	// A new append must continue from the recovered head, not restart at 1.
	if err := l.Append(domain.Event{ID: "c", Type: domain.EventDeposited, Amount: "1"}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	tail, err := l.ReadAfter(context.Background(), 2, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(tail) != 1 || tail[0].Seq != 3 {
		t.Fatalf("append after a pre-v3 log landed at %+v, want position 3", tail)
	}
}
