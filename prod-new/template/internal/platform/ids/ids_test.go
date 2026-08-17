package ids

import (
	"sync"
	"testing"
)

// provenance: derived
// verifies: injected id/random port (real generator produces distinct,
// well-formed ids)
func TestReal_NewID_ProducesDistinctWellFormedIDs(t *testing.T) {
	g := Real{}
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id := g.NewID()
		if len(id) != 32 {
			t.Fatalf("NewID() = %q, want 32 hex chars", id)
		}
		if seen[id] {
			t.Fatalf("NewID() produced a duplicate: %q", id)
		}
		seen[id] = true
	}
}

// provenance: derived
// verifies: injected id/random port (deterministic sequence for tests,
// concurrency-safe)
func TestSequential_NewID_IsDeterministicAndConcurrencySafe(t *testing.T) {
	g := NewSequential()
	if got := g.NewID(); got != "seq-1" {
		t.Fatalf("first NewID() = %q, want seq-1", got)
	}
	if got := g.NewID(); got != "seq-2" {
		t.Fatalf("second NewID() = %q, want seq-2", got)
	}

	g2 := NewSequential()
	const n = 500
	seen := make(chan string, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			seen <- g2.NewID()
		}()
	}
	wg.Wait()
	close(seen)
	unique := map[string]bool{}
	for id := range seen {
		if unique[id] {
			t.Fatalf("concurrent NewID() produced a duplicate: %q", id)
		}
		unique[id] = true
	}
	if len(unique) != n {
		t.Fatalf("got %d unique ids, want %d", len(unique), n)
	}
}
