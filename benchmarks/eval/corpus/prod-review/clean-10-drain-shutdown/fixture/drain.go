// Package drain tracks in-flight jobs for a service that must shut down cleanly.
package drain

import (
	"context"
	"errors"
	"sync"
)

// ErrClosed is returned by Go once the coordinator has stopped accepting work.
var ErrClosed = errors.New("coordinator is closed")

// Job is one unit of work. It should return promptly once ctx is cancelled.
type Job func(ctx context.Context) error

// Coordinator starts jobs and keeps count of the ones still running.
type Coordinator struct {
	mu     sync.Mutex
	closed bool
	wg     sync.WaitGroup
	ctx    context.Context
	cancel context.CancelFunc
}

// New returns a coordinator whose jobs see a context derived from parent.
func New(parent context.Context) *Coordinator {
	ctx, cancel := context.WithCancel(parent)
	return &Coordinator{ctx: ctx, cancel: cancel}
}

// Go runs job on its own goroutine, or returns ErrClosed if the coordinator
// has stopped accepting work. The job's error is discarded.
func (c *Coordinator) Go(job Job) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ErrClosed
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		_ = job(c.ctx)
	}()
	return nil
}
