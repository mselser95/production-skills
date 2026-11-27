package lease

import (
	"testing"
	"time"
)

func TestNewKeeperRejectsNonPositiveTTL(t *testing.T) {
	t.Parallel()
	c := NewFakeClock(time.Unix(0, 0))
	for _, ttl := range []time.Duration{0, -time.Second} {
		if _, err := NewKeeper(c, ttl); err != ErrTTL {
			t.Fatalf("ttl %v: err = %v", ttl, err)
		}
	}
	if _, err := NewKeeper(c, time.Second); err != nil {
		t.Fatal(err)
	}
}
