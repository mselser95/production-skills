package quota

import (
	"testing"
	"time"
)

func newMeter(t *testing.T, limit int64) *Meter {
	t.Helper()
	m, err := New(limit, 24*time.Hour, func() time.Time { return time.Unix(1_000_000, 0) })
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestChargeUpToLimit(t *testing.T) {
	m := newMeter(t, 10)
	if err := m.Charge("a", 6); err != nil {
		t.Fatal(err)
	}
	if err := m.Charge("a", 4); err != nil {
		t.Fatal(err)
	}
	if err := m.Charge("a", 1); err != ErrLimit {
		t.Fatalf("got %v, want ErrLimit", err)
	}
}

func TestTenantsAreIndependent(t *testing.T) {
	m := newMeter(t, 5)
	if err := m.Charge("a", 5); err != nil {
		t.Fatal(err)
	}
	if err := m.Charge("b", 5); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsNonPositive(t *testing.T) {
	m := newMeter(t, 5)
	for _, n := range []int64{0, -1} {
		if err := m.Charge("a", n); err != ErrAmount {
			t.Fatalf("n=%d: got %v", n, err)
		}
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	now := func() time.Time { return time.Time{} }
	if _, err := New(-1, time.Hour, now); err != ErrConfig {
		t.Fatal("negative limit accepted")
	}
	if _, err := New(1, 0, now); err != ErrConfig {
		t.Fatal("zero window accepted")
	}
}
