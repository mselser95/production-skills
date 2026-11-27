package jobs

import (
	"context"
	"errors"
	"testing"
)

func TestSerialOrderAndStop(t *testing.T) {
	var ran []int
	boom := errors.New("boom")
	mk := func(i int, err error) Job {
		return func(context.Context) error { ran = append(ran, i); return err }
	}
	err := Serial(context.Background(), []Job{mk(1, nil), mk(2, boom), mk(3, nil)})
	if !errors.Is(err, boom) || len(ran) != 2 {
		t.Fatalf("err = %v, ran = %v", err, ran)
	}
}

func TestSerialCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	err := Serial(ctx, []Job{func(context.Context) error { called = true; return nil }})
	if !errors.Is(err, context.Canceled) || called {
		t.Fatalf("err = %v, called = %v", err, called)
	}
}
