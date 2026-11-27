package retry

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ErrExhausted wraps the last error once every attempt has failed.
var ErrExhausted = errors.New("retry: attempts exhausted")

// Policy bounds a retry loop.
type Policy struct {
	Attempts int
	Delay    time.Duration
}

// Do calls fn up to p.Attempts times, sleeping p.Delay between failures.
func Do(ctx context.Context, p Policy, fn func(context.Context) error) error {
	var last error
	for i := 0; i < p.Attempts; i++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if last = fn(ctx); last == nil {
			return nil
		}
		time.Sleep(p.Delay)
	}
	return fmt.Errorf("%w: %v", ErrExhausted, last)
}
