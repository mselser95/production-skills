package app

import (
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// checkInvariants is the RUNTIME mirror of this service's two ratified
// invariants (verification/ratified/invariants_test.go), run after every
// real domain.Apply call inside process(). It is deliberately independent
// of Apply's own control flow -- domain.ConservationHolds recomputes what
// the RIGHT after-state should have been from (before, event) and compares
// it to what Apply actually returned, so a future bug that breaks Apply's
// arithmetic is caught here too, not only by the test suite. A violation
// increments a counter (mirrored to Prometheus by
// internal/adapter/in/healthhttp as clcsvc_units_conserved_violations_total
// / clcsvc_duplicate_event_violations_total) and records when it happened,
// which internal/adapter/in/healthhttp's readiness gate reads.
func (l *Ledger) checkInvariants(before domain.State, event domain.Event, after domain.State) {
	if !domain.ConservationHolds(before, event, after) {
		l.conservationViolations.Add(1)
		l.lastViolationUnixNano.Store(l.clock().UnixNano())
	}
	if before.Applied[event.ID] && after.Balance != before.Balance {
		l.duplicateEffectViolation.Add(1)
		l.lastViolationUnixNano.Store(l.clock().UnixNano())
	}
}

// CheckInvariantsForTest runs the exact same runtime check process() runs
// after every real command, but callable directly with an arbitrary
// (before, event, after) triple. It exists so the counters below can be
// PROVEN wired to something that can actually fire -- driven with a
// deliberately inconsistent triple that domain.Apply's own real control
// flow could never produce -- without mutating this package's source to
// manufacture a violation (see TestConservationViolations_Increments... in
// ledger_invariants_test.go, mirroring the same discipline
// internal/adapter/in/healthhttp uses for its own counters).
func (l *Ledger) CheckInvariantsForTest(before domain.State, event domain.Event, after domain.State) {
	l.checkInvariants(before, event, after)
}

// ConservationViolations returns how many times checkInvariants has
// detected a units-conservation mismatch. Must stay 0 under every
// legitimate command sequence.
func (l *Ledger) ConservationViolations() int64 { return l.conservationViolations.Load() }

// DuplicateEffectViolations returns how many times checkInvariants has
// detected a duplicate-ID event that nonetheless changed the balance. Must
// stay 0 under every legitimate command sequence -- domain.Apply's own
// idempotency guard is what keeps it at 0 in real operation.
func (l *Ledger) DuplicateEffectViolations() int64 { return l.duplicateEffectViolation.Load() }

// LastInvariantViolationAt returns when the most recent violation (of
// either kind) was recorded, or the zero time.Time if none has ever
// occurred. internal/adapter/in/healthhttp's readiness gate fails for a
// configurable cooldown window after this -- see that package's Server.
func (l *Ledger) LastInvariantViolationAt() time.Time {
	n := l.lastViolationUnixNano.Load()
	if n == 0 {
		return time.Time{}
	}
	return time.Unix(0, n)
}
