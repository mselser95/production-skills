// Package bucket is a token bucket that refills at a steady rate.
package bucket

import (
	"errors"
	"sync"
	"time"
)

// ErrConfig is returned for a capacity or rate that cannot be served.
var ErrConfig = errors.New("invalid bucket config")

// Bucket holds up to capacity tokens and refills perSec tokens each second.
type Bucket struct {
	mu       sync.Mutex
	now      func() time.Time
	capacity int64
	perSec   int64
	tokens   int64
	last     time.Time
}

// New returns a full Bucket. now is the clock; nil means time.Now.
func New(capacity, perSec int64, now func() time.Time) (*Bucket, error) {
	if capacity < 1 || perSec < 1 {
		return nil, ErrConfig
	}
	if now == nil {
		now = time.Now
	}
	return &Bucket{now: now, capacity: capacity, perSec: perSec, tokens: capacity, last: now()}, nil
}

// Allow takes n tokens if they are available and reports whether it did.
func (b *Bucket) Allow(n int64) bool {
	if n < 1 {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refill(b.now())
	if n > b.tokens {
		return false
	}
	b.tokens -= n
	return true
}

// refill credits whole seconds only, so a sub-second wait earns nothing.
func (b *Bucket) refill(now time.Time) {
	secs := int64(now.Sub(b.last) / time.Second)
	if secs <= 0 {
		return
	}
	b.tokens = min(b.capacity, b.tokens+secs*b.perSec)
	b.last = b.last.Add(time.Duration(secs) * time.Second)
}
