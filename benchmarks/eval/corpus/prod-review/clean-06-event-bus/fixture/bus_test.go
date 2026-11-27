package events

import "testing"

func TestSubscribeAndUnsubscribe(t *testing.T) {
	b := New()
	un := b.Subscribe("a", func(Event) {})
	b.Subscribe("a", func(Event) {})
	if got := b.Subscribers("a"); got != 2 {
		t.Fatalf("Subscribers = %d, want 2", got)
	}
	un()
	un()
	if got := b.Subscribers("a"); got != 1 {
		t.Fatalf("after unsubscribe Subscribers = %d, want 1", got)
	}
	if got := b.Subscribers("missing"); got != 0 {
		t.Fatalf("Subscribers(missing) = %d, want 0", got)
	}
}
