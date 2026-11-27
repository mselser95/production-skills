package ratelimit

import (
	"sync"
	"time"
)

// Limiter is a token bucket: it refills at rate tokens per second up to burst.
type Limiter struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

// New returns a full bucket. A nil now defaults to time.Now.
func New(rate float64, burst int, now func() time.Time) *Limiter {
	if now == nil {
		now = time.Now
	}
	return &Limiter{rate: rate, burst: float64(burst), tokens: float64(burst), last: now(), now: now}
}

// Allow takes one token if one is available.
func (l *Limiter) Allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	l.tokens += t.Sub(l.last).Seconds() * l.rate
	if l.tokens > l.burst {
		l.tokens = l.burst
	}
	l.last = t
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}
