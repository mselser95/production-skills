package idem

import (
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time { return f.t }

func TestPutGet(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	c := New(time.Minute, clk.now)
	c.Put("k", []byte("v"))
	if v, ok := c.Get("k"); !ok || string(v) != "v" {
		t.Fatalf("get = %q, %v", v, ok)
	}
	if _, ok := c.Get("other"); ok {
		t.Fatal("unexpected hit")
	}
}

func TestExpiry(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	c := New(time.Minute, clk.now)
	c.Put("k", []byte("v"))
	clk.t = clk.t.Add(59 * time.Second)
	if _, ok := c.Get("k"); !ok {
		t.Fatal("expired too early")
	}
	clk.t = clk.t.Add(time.Second)
	if _, ok := c.Get("k"); ok {
		t.Fatal("served at its expiry")
	}
	if c.Len() != 0 {
		t.Fatalf("len = %d, want 0", c.Len())
	}
}
