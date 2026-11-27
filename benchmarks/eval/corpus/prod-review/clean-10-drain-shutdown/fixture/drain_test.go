package drain

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
)

func TestGoRunsJob(t *testing.T) {
	c := New(context.Background())
	var ran atomic.Bool
	ch := make(chan struct{})
	if err := c.Go(func(context.Context) error { ran.Store(true); close(ch); return nil }); err != nil {
		t.Fatal(err)
	}
	<-ch
	if !ran.Load() {
		t.Fatal("job did not run")
	}
}

func TestGoAfterCloseIsRefused(t *testing.T) {
	c := New(context.Background())
	c.closed = true
	if err := c.Go(func(context.Context) error { return nil }); !errors.Is(err, ErrClosed) {
		t.Fatalf("got %v, want ErrClosed", err)
	}
}
