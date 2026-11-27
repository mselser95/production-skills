package ratelimit

import (
	"testing"
	"time"
)

func TestAllowBurstThenRefill(t *testing.T) {
	now := time.Unix(1000, 0)
	l := New(1, 2, func() time.Time { return now })
	if !l.Allow() || !l.Allow() {
		t.Fatal("burst of 2 should be allowed")
	}
	if l.Allow() {
		t.Fatal("third call should be limited")
	}
	now = now.Add(1500 * time.Millisecond)
	if !l.Allow() {
		t.Fatal("one token should have refilled")
	}
	if l.Allow() {
		t.Fatal("only one token should have refilled")
	}
}
