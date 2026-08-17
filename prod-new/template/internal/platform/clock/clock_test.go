package clock

import (
	"testing"
	"time"
)

// provenance: derived
// verifies: injected clock port (operational determinism -- Output =
// F(code, config, state, inputs), and `inputs` includes time)
func TestReal_ReturnsATimeCloseToNow(t *testing.T) {
	before := time.Now()
	got := Real{}.Now()
	after := time.Now()
	if got.Before(before) || got.After(after) {
		t.Fatalf("Real{}.Now() = %v, want between %v and %v", got, before, after)
	}
}

// provenance: derived
// verifies: injected clock port (deterministic fake for tests)
func TestFake_AdvanceAndSet(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	f := NewFake(start)
	if !f.Now().Equal(start) {
		t.Fatalf("Now() = %v, want %v", f.Now(), start)
	}
	f.Advance(5 * time.Minute)
	if want := start.Add(5 * time.Minute); !f.Now().Equal(want) {
		t.Fatalf("after Advance: Now() = %v, want %v", f.Now(), want)
	}
	other := start.Add(-time.Hour)
	f.Set(other)
	if !f.Now().Equal(other) {
		t.Fatalf("after Set: Now() = %v, want %v", f.Now(), other)
	}
}
