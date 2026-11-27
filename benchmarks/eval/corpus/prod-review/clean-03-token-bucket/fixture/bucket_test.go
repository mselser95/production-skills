package bucket

import (
	"errors"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time { return f.t }

func TestAllowAndRefill(t *testing.T) {
	clk := &fakeClock{t: time.Unix(0, 0)}
	b, err := New(5, 2, clk.now)
	if err != nil {
		t.Fatal(err)
	}
	if !b.Allow(5) || b.Allow(1) {
		t.Fatal("full bucket should give exactly 5 tokens")
	}
	clk.t = clk.t.Add(2 * time.Second)
	if !b.Allow(4) || b.Allow(1) {
		t.Fatal("2s at 2/s should give exactly 4 tokens")
	}
}

func TestConfigAndInput(t *testing.T) {
	if _, err := New(0, 1, nil); !errors.Is(err, ErrConfig) {
		t.Fatalf("err = %v, want ErrConfig", err)
	}
	b, _ := New(3, 1, nil)
	if b.Allow(0) || b.Allow(-1) || b.Allow(4) {
		t.Fatal("zero, negative and over-capacity requests must be refused")
	}
}
