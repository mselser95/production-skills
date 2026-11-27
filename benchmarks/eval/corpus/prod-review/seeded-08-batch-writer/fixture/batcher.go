// Package batch groups items and hands them to a sink in batches.
package batch

import "sync"

// Sink receives one full batch. It may fail; the batch is then not consumed.
type Sink func(items []string) error

// Batcher buffers items and flushes them to its Sink once max are waiting.
type Batcher struct {
	mu   sync.Mutex
	buf  []string
	max  int
	sink Sink
}

// New returns a Batcher that flushes every max items. max below 1 means 1.
func New(max int, sink Sink) *Batcher {
	if max < 1 {
		max = 1
	}
	return &Batcher{max: max, sink: sink}
}

// Add queues item and flushes if the batch is full. If the flush fails the
// items stay queued for the next attempt and the error is returned.
func (b *Batcher) Add(item string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, item)
	if len(b.buf) < b.max {
		return nil
	}
	return b.flushLocked()
}

// Flush sends whatever is queued, even if the batch is not full.
func (b *Batcher) Flush() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.flushLocked()
}

// Pending reports how many items are queued.
func (b *Batcher) Pending() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.buf)
}

func (b *Batcher) flushLocked() error {
	if len(b.buf) == 0 {
		return nil
	}
	if err := b.sink(b.buf); err != nil {
		return err
	}
	b.buf = nil
	return nil
}
