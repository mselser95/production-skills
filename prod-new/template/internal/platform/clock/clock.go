// Package clock is the wall-clock PORT this service injects everywhere a
// component needs to know "now". internal/domain and internal/app never
// call time.Now() directly (internal/architecture/boundaries_test.go
// enforces this over domain+app); every caller that needs the current time
// receives one of the func values this package builds, so tests can
// substitute a deterministic fake instead of racing the real clock.
package clock

import "time"

// Clock reports the current time. The real implementation is time.Now
// itself (see Real); tests use NewFake for a deterministic, manually
// advanced clock.
type Clock interface {
	Now() time.Time
}

// Real is the production Clock: every call delegates to time.Now(). This is
// the ONE place in the whole module allowed to read the wall clock directly
// outside of tests -- internal/platform is exempt from the core's wall-clock
// ban (see internal/architecture/boundaries_test.go's allowlist doc), and
// this is that exemption's entire justification: everything else gets time
// through the Clock port, real or fake.
type Real struct{}

// Now returns time.Now().
func (Real) Now() time.Time { return time.Now() }

// Fake is a deterministic, manually advanced Clock for tests. The zero
// value is usable (starts at the zero time.Time) but NewFake with an
// explicit start is almost always clearer at the call site.
type Fake struct {
	now time.Time
}

// NewFake returns a Fake clock initialized to start.
func NewFake(start time.Time) *Fake {
	return &Fake{now: start}
}

// Now returns the fake clock's current time.
func (f *Fake) Now() time.Time { return f.now }

// Advance moves the fake clock forward by d (d may be negative to move it
// backward, e.g. to construct a "this was stale as of now" test scenario).
func (f *Fake) Advance(d time.Duration) { f.now = f.now.Add(d) }

// Set pins the fake clock to an exact time.
func (f *Fake) Set(t time.Time) { f.now = t }
