package domain

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fixtureEvent is regressions/<slug>/events.json's per-entry shape.
type fixtureEvent struct {
	ID     string `json:"id"`
	Type   string `json:"type"`
	Amount string `json:"amount"`
	Note   string `json:"note"`
}

// loadExpectFinalBalance does a minimal, dependency-free scan of
// fixture.yaml for the `expect_final_balance: "..."` line -- this module
// carries no YAML dependency and the format is simple enough not to need
// one (mirrors internal/platform/eventlog's own JSONL-only discipline).
func loadExpectFinalBalance(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	const key = "expect_final_balance:"
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(trimmed, key); ok {
			return strings.Trim(strings.TrimSpace(rest), `"`)
		}
	}
	t.Fatalf("%s has no expect_final_balance: line", path)
	return ""
}

// provenance: derived
// verifies: recovery/replay (tier-policy: event-sourcing-flavored
// regression capability -- regressions/ corpus, driven through the REAL
// decode(none, this domain has no wire decode of its own)->core
// (domain.Apply)->serve(final state) path, asserting invariants at every
// transition, never golden state)
//
// Discovers every regressions/<yyyy-mm-dd>-<slug>/ fixture automatically
// (no registry to keep in sync) and fails if fewer than 1 is found, so the
// corpus cannot silently shrink to zero.
func TestReplayCorpus(t *testing.T) {
	root := regressionsRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}

	found := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		found++
		dir := filepath.Join(root, entry.Name())
		t.Run(entry.Name(), func(t *testing.T) { runFixture(t, dir) })
	}
	if found == 0 {
		t.Fatalf("no fixture directories found under %s -- the replay corpus has shrunk to zero", root)
	}
}

func runFixture(t *testing.T, dir string) {
	t.Helper()
	eventsPath := filepath.Join(dir, "events.json")
	raw, err := os.ReadFile(eventsPath)
	if err != nil {
		t.Fatalf("read %s: %v", eventsPath, err)
	}
	var fixtureEvents []fixtureEvent
	if err := json.Unmarshal(raw, &fixtureEvents); err != nil {
		t.Fatalf("decode %s: %v", eventsPath, err)
	}
	if len(fixtureEvents) == 0 {
		t.Fatalf("%s decoded to zero events", eventsPath)
	}

	state := NewState()
	for i, fe := range fixtureEvents {
		event := Event{ID: fe.ID, Type: EventType(fe.Type), Amount: fe.Amount}
		before := state
		after, effects := Apply(before, event)

		if !ConservationHolds(before, event, after) {
			t.Fatalf("step %d (%s): ConservationHolds failed for before=%+v event=%+v after=%+v", i, fe.Note, before, event, after)
		}
		if len(effects) == 0 {
			t.Fatalf("step %d (%s): Apply returned zero effects", i, fe.Note)
		}
		state = after
	}

	wantFinal := loadExpectFinalBalance(t, filepath.Join(dir, "fixture.yaml"))
	if state.Balance != wantFinal {
		t.Fatalf("final balance = %q, want %q (fixture.yaml's expect_final_balance)", state.Balance, wantFinal)
	}
}

func regressionsRoot(t *testing.T) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate this test file")
	}
	// this file: internal/domain/replay_corpus_test.go
	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", "regressions"))
}
