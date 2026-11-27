package retry

import (
	"context"
	"errors"
	"testing"
)

func TestDoSucceedsAfterFailures(t *testing.T) {
	calls := 0
	err := Do(context.Background(), Policy{Attempts: 3}, func(context.Context) error {
		calls++
		if calls < 3 {
			return errors.New("boom")
		}
		return nil
	})
	if err != nil || calls != 3 {
		t.Fatalf("err = %v, calls = %d", err, calls)
	}
}

func TestDoExhausts(t *testing.T) {
	err := Do(context.Background(), Policy{Attempts: 2}, func(context.Context) error { return errors.New("boom") })
	if !errors.Is(err, ErrExhausted) {
		t.Fatalf("err = %v", err)
	}
}
