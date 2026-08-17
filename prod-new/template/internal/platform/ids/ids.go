// Package ids is the ID-generation / randomness PORT this service injects
// everywhere a component needs a fresh identifier or a random choice.
// internal/domain never generates one (pure core: an event's ID is supplied
// by the caller, never invented inside Apply); internal/app receives a
// Generator (or, to stay import-free per
// internal/architecture/boundaries_test.go, the bare NewID func value it
// exposes) at construction so tests can substitute a deterministic
// sequence instead of depending on crypto/rand's real unpredictability.
package ids

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync/atomic"
)

// Generator produces fresh, effectively-unique identifiers on demand.
type Generator interface {
	NewID() string
}

// Real is the production Generator: every call reads 16 bytes from
// crypto/rand and hex-encodes them (a 128-bit random id, collision
// probability negligible at this service's scale -- no coordination
// between replicas is needed because the ID SPACE, not a counter, is what
// makes collisions rare).
type Real struct{}

// NewID returns a fresh random 32-hex-character identifier. Panics only if
// the system CSPRNG itself fails (crypto/rand.Read's documented failure
// mode, which in practice means the OS entropy source is broken -- not a
// condition any caller could meaningfully recover from, so this matches
// the stdlib's own convention of treating a crypto/rand.Read failure as
// fatal rather than plumbing an error return through every ID-generating
// call site in the codebase).
func (Real) NewID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		panic(fmt.Sprintf("ids: crypto/rand.Read failed: %v", err))
	}
	return hex.EncodeToString(buf)
}

// Sequential is a deterministic Generator for tests: NewID returns
// "seq-<n>" for n = 1, 2, 3, ... in call order. Safe for concurrent use.
type Sequential struct {
	counter atomic.Uint64
}

// NewSequential returns a Sequential generator starting at "seq-1".
func NewSequential() *Sequential { return &Sequential{} }

// NewID returns the next sequential id.
func (s *Sequential) NewID() string {
	n := s.counter.Add(1)
	return fmt.Sprintf("seq-%d", n)
}
