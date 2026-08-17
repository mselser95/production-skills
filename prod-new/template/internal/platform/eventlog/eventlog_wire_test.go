package eventlog

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// provenance: derived
// verifies: compatibility (tier-policy: compatibility.schema = expand_contract,
// breaking_check required) -- a GOLDEN fixture of the on-disk record format,
// so a future field rename/removal is caught here instead of silently
// changing what an already-written production log means. This is an N-1
// check: a log written by an OLDER build of this schema_version must still
// Replay correctly under the CURRENT code.
func TestEventlog_GoldenRecordFormatIsStillReadable(t *testing.T) {
	golden := filepath.Join("testdata", "golden_v1.jsonl")
	data, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden fixture: %v", err)
	}
	path := filepath.Join(t.TempDir(), "replay.jsonl")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write temp copy: %v", err)
	}

	events, err := Replay(path)
	if err != nil {
		t.Fatalf("Replay(golden fixture): %v", err)
	}
	want := []domain.Event{
		{ID: "golden-1", Type: domain.EventDeposited, Amount: "42.5"},
		{ID: "golden-2", Type: domain.EventWithdrawn, Amount: "10"},
	}
	if len(events) != len(want) {
		t.Fatalf("got %d events from the golden fixture, want %d", len(events), len(want))
	}
	for i := range want {
		if events[i] != want[i] {
			t.Fatalf("golden event %d = %+v, want %+v -- the wire format has drifted from schema_version %d's committed shape", i, events[i], want[i], SchemaVersion)
		}
	}
}
