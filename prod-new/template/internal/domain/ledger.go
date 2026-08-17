package domain

import "sort"

// EventType is the closed set of things that can happen to the units
// ledger. A third case is never added silently -- Apply's switch has a
// default branch that returns the event untouched with an
// EffectUnknownEventType, so an unrecognized type is a visible, counted
// event rather than a silent no-op.
type EventType string

const (
	// EventDeposited increases the ledger's balance by Event.Amount.
	EventDeposited EventType = "deposited"
	// EventWithdrawn decreases the ledger's balance by Event.Amount, if and
	// only if the balance can cover it (see Apply) -- this domain's balance
	// is never allowed to go negative.
	EventWithdrawn EventType = "withdrawn"
)

// Event is one entry in the append-only ledger log. ID is the idempotency
// key: Apply is defined so that applying the SAME ID twice has the ledger's
// economic effect exactly once (see State.Applied and
// TestInvariant_DuplicateEventAppliedOnce in verification/ratified).
type Event struct {
	ID     string
	Type   EventType
	Amount string // decimal string, ParseAmount-shaped, always non-negative
}

// State is the ledger's full state: current balance, plus the set of event
// IDs already folded in (idempotency bookkeeping) and a monotonic version
// counter (incremented once per event actually admitted, including a
// no-op-because-duplicate admission, so Version is a count of Apply calls
// that reached a decision -- see (State).Clone for why this is copied, not
// aliased, on every transition).
type State struct {
	Balance string
	Applied map[string]bool
	Version uint64
}

// NewState returns the ledger's zero state: no balance, no applied events.
func NewState() State {
	return State{Balance: ZeroAmount, Applied: map[string]bool{}}
}

// Clone returns a deep copy of s. domain.Apply always returns a Clone-based
// state rather than mutating its input in place: State is handed across
// goroutine boundaries by internal/app (guarded by its own mutex, but the
// pure core must not depend on that -- see the package doc's "no
// goroutines" rule, which is about not STARTING one, not about being safe
// to alias across one), and a function that mutates a map it was handed a
// reference to is not a pure function by this package's own definition.
func (s State) Clone() State {
	applied := make(map[string]bool, len(s.Applied))
	for k, v := range s.Applied {
		applied[k] = v
	}
	return State{Balance: s.Balance, Applied: applied, Version: s.Version}
}

// AppliedIDs returns the applied event IDs in sorted order -- deterministic
// output from a map-backed field, for tests and for anything that ever
// needs to render State reproducibly (a replay diff, a golden fixture).
func (s State) AppliedIDs() []string {
	out := make([]string, 0, len(s.Applied))
	for id := range s.Applied {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// Effect is anything Apply decides happened as a side effect of admitting
// (or rejecting, or no-op-ing) an event. Effects carry no I/O of their own
// -- internal/app decides what to do with them (e.g. journal an
// EffectDeposited/EffectWithdrawn through the outbox for external
// notification; see internal/adapter/out/store).
type Effect interface {
	isEffect()
}

// EffectDeposited is emitted when a deposit is admitted for the first time.
type EffectDeposited struct {
	EventID string
	Amount  string
}

func (EffectDeposited) isEffect() {}

// EffectWithdrawn is emitted when a withdrawal is admitted for the first
// time.
type EffectWithdrawn struct {
	EventID string
	Amount  string
}

func (EffectWithdrawn) isEffect() {}

// EffectWithdrawalRejected is emitted when a withdrawal is rejected because
// it would drive the balance negative. This is an EXPECTED, correctly-
// handled outcome, not an invariant violation -- the ledger's own conserved-
// balance invariant is exactly what this rejection protects.
type EffectWithdrawalRejected struct {
	EventID string
	Amount  string
	Reason  string
}

func (EffectWithdrawalRejected) isEffect() {}

// EffectDuplicateIgnored is emitted when an event ID that has already been
// applied is submitted again. The ledger's balance and version are
// unchanged; this Effect is purely informational (an app-layer caller may
// want to log or count it), never an error.
type EffectDuplicateIgnored struct {
	EventID string
}

func (EffectDuplicateIgnored) isEffect() {}

// EffectUnknownEventType is emitted when Event.Type is not one of the
// declared constants. State is unchanged. This exists so an unrecognized
// event type is a visible, testable outcome instead of Apply silently
// falling through a switch with no default.
type EffectUnknownEventType struct {
	EventID string
	Type    EventType
}

func (EffectUnknownEventType) isEffect() {}

// EffectMalformedAmount is emitted when Event.Amount fails ParseAmount.
// State is unchanged.
type EffectMalformedAmount struct {
	EventID string
	Amount  string
	Err     string
}

func (EffectMalformedAmount) isEffect() {}

// Apply is the event-sourced core's single decision function: given the
// current State and the next Event, it returns the State that results and
// the Effects that decision produced. Apply is TOTAL -- it never panics and
// never returns an error; every rejection (insufficient balance, malformed
// amount, unknown type) is represented as an Effect instead, because a pure
// core cannot signal failure any other way without either panicking (never,
// for arbitrary caller input) or returning an error the caller could ignore
// (an ignored error silently drops the ledger update; an ignored Effect
// slice element is still visible in the return value and easy for a test to
// assert against).
//
// Idempotency: if event.ID has already been applied (state.Applied[ID] is
// true), Apply returns state UNCHANGED (not even a Clone -- see
// TestApply_DuplicateEventIDIsANoOp) plus a single EffectDuplicateIgnored.
// This is what makes "an event applied twice has the economic effect once"
// a property of Apply itself, provable by calling it twice with the same
// Event and asserting the second call's returned State equals the first
// call's (see verification/ratified/invariants_test.go).
func Apply(state State, event Event) (State, []Effect) {
	if state.Applied[event.ID] {
		return state, []Effect{EffectDuplicateIgnored{EventID: event.ID}}
	}
	if err := ValidateAmount(event.Amount); err != nil {
		return state, []Effect{EffectMalformedAmount{EventID: event.ID, Amount: event.Amount, Err: err.Error()}}
	}

	switch event.Type {
	case EventDeposited:
		next := state.Clone()
		newBalance, err := AddAmounts(state.Balance, event.Amount)
		if err != nil {
			// ValidateAmount already accepted event.Amount and state.Balance
			// is always ValidateAmount-shaped by construction (every prior
			// transition through Apply produced it) -- this branch is
			// unreachable in practice and exists only so AddAmounts' error
			// is never silently discarded.
			return state, []Effect{EffectMalformedAmount{EventID: event.ID, Amount: event.Amount, Err: err.Error()}}
		}
		next.Balance = newBalance
		next.Applied[event.ID] = true
		next.Version++
		return next, []Effect{EffectDeposited{EventID: event.ID, Amount: event.Amount}}

	case EventWithdrawn:
		cmp, err := CompareAmounts(event.Amount, state.Balance)
		if err != nil {
			return state, []Effect{EffectMalformedAmount{EventID: event.ID, Amount: event.Amount, Err: err.Error()}}
		}
		if cmp > 0 {
			// Insufficient balance: rejected, not applied. The event ID is
			// deliberately NOT marked Applied here -- a rejected withdrawal
			// carries no economic effect to make idempotent, and marking it
			// would make a LATER, legitimate retry of the same ID (e.g.
			// after a deposit raises the balance) permanently impossible.
			return state, []Effect{EffectWithdrawalRejected{EventID: event.ID, Amount: event.Amount, Reason: "insufficient balance"}}
		}
		next := state.Clone()
		newBalance, err := SubAmounts(state.Balance, event.Amount)
		if err != nil {
			return state, []Effect{EffectMalformedAmount{EventID: event.ID, Amount: event.Amount, Err: err.Error()}}
		}
		next.Balance = newBalance
		next.Applied[event.ID] = true
		next.Version++
		return next, []Effect{EffectWithdrawn{EventID: event.ID, Amount: event.Amount}}

	default:
		return state, []Effect{EffectUnknownEventType{EventID: event.ID, Type: event.Type}}
	}
}

// ConservationHolds is the RUNTIME-CHECKABLE form of this domain's central
// invariant: applying `event` to `before` must yield a `after` whose balance
// is exactly before.Balance plus the event's signed economic effect (zero
// for a rejected withdrawal, a malformed/unknown event, or a duplicate ID).
// internal/app calls this after every real Apply call and increments a
// counter (mirrored to Prometheus as a ratified-invariant series) if it
// ever returns false -- see internal/app's applyAndCheck. It is exported
// and pure specifically so it can also be called DIRECTLY with a
// deliberately inconsistent (before, after) pair in a test, to prove the
// counter that wraps it is wired to something that can actually fire (see
// TestConservationViolationCounter_IncrementsOnDeliberateViolation in
// internal/app), without needing to mutate this package's source to
// manufacture a violation.
func ConservationHolds(before State, event Event, after State) bool {
	if before.Applied[event.ID] {
		// Was already applied before this call: Apply defines this as a
		// strict no-op, so after must equal before exactly (same balance,
		// same version -- Apply returns `state` itself unchanged, not a
		// Clone, for this case).
		return after.Balance == before.Balance && after.Version == before.Version
	}
	if err := ValidateAmount(event.Amount); err != nil {
		return after.Balance == before.Balance && after.Version == before.Version
	}
	switch event.Type {
	case EventDeposited:
		want, err := AddAmounts(before.Balance, event.Amount)
		if err != nil {
			return after.Balance == before.Balance
		}
		return after.Balance == want && after.Version == before.Version+1
	case EventWithdrawn:
		cmp, err := CompareAmounts(event.Amount, before.Balance)
		if err != nil {
			return after.Balance == before.Balance
		}
		if cmp > 0 {
			// Rejected: unchanged.
			return after.Balance == before.Balance && after.Version == before.Version
		}
		want, err := SubAmounts(before.Balance, event.Amount)
		if err != nil {
			return after.Balance == before.Balance
		}
		return after.Balance == want && after.Version == before.Version+1
	default:
		return after.Balance == before.Balance && after.Version == before.Version
	}
}
