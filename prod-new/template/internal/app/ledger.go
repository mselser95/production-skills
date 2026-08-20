// Package app is the durable orchestration zone: it drives
// internal/domain's pure Apply function through a real command-processing
// pipeline with an injected clock/id source, a durable event journal, and
// a relay that publishes committed events outward.
//
// It deliberately imports NEITHER internal/adapter NOR internal/platform
// (see internal/architecture/boundaries_test.go's
// TestHexagonalBoundaries/internal_app case): every port this package
// needs from those zones is declared HERE, using only primitive types and
// internal/domain types, and satisfied STRUCTURALLY by the concrete
// adapter/platform implementations without either side importing the
// other. This is the same trick internal/adapter/in/healthhttp's ConnHealth
// port and internal/app's own historical SpanFunc pattern use in the
// reference implementation this template is built from -- Go interfaces
// need no shared import to be satisfied.
package app

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// Clock is the wall-clock port, satisfied structurally by
// internal/platform/clock.Clock.Now (a method value) or any func() time.Time.
type Clock func() time.Time

// IDGenerator is the injected id/randomness port, satisfied structurally by
// internal/platform/ids.Generator.NewID (a method value) or any
// func() string. Every event's idempotency key is minted through this port,
// never inline with crypto/rand or time-based uniqueness, so tests can
// supply a deterministic sequence.
type IDGenerator func() string

// EventJournal is the durable append-only log port. Satisfied structurally
// by internal/platform/eventlog.(*Log).Append.
//
// The ctx is the SPAN-CARRYING context returned by SpanFunc, and threading it
// here is the load-bearing half of trace correlation in this service, not
// politeness. The log is the outbox: the relay publishes this record later,
// from another goroutine and possibly another process, so the only way the
// publish can belong to the trace that committed the fact is for the journal
// to persist the caller's traceparent with it. Drop the ctx and every
// published event is a fresh root, which is exactly the shape that produced
// 3132 traces for 3132 spans in a service where every mechanism was correct
// on its own.
type EventJournal interface {
	Append(ctx context.Context, event domain.Event) error
}

// Notifier tells the relay that new events are available, so a healthy
// deployment delivers immediately instead of waiting out the relay's idle
// interval. Satisfied by internal/platform/relay.(*Relay).Notify.
//
// It must never block. This is the write path: anything that can block here
// puts the network back in front of a command, which is the coupling the
// relay exists to remove.
//
// There is deliberately no publisher port here at all. THE EVENT LOG IS THE
// OUTBOX -- the relay tails it and publishes what it finds, so this layer's
// entire delivery responsibility is one durable append plus a nudge. An
// earlier design journaled effects to a SECOND durable store here; that
// store held no information the log did not already imply, and the window
// between the two writes could lose an effect for a fact that had already
// committed.
type Notifier func()

// SpanFunc is the narrow tracing port app needs, satisfied structurally by
// internal/platform/observability.Tracer.StartSpan (adapted at the
// composition root) without importing that package. A Ledger built without
// SetTracer uses noopSpan below, so tracing is additive and costs nothing by
// default.
//
// THE CONTEXT IS THREADED IN BOTH DIRECTIONS, and neither direction is
// decoration.
//
//   - INBOUND, so the span is a CHILD of whatever the caller was already
//     doing rather than a new orphan root. This port used to take no context
//     at all, so the composition root had nothing to pass and started every
//     span from context.Background().
//   - OUTBOUND, so this layer can hand the span-carrying context to
//     everything it calls -- which is the only way a durable record can carry
//     the traceparent of the command that wrote it, and the only way a log
//     line emitted during the span can carry that span's trace id.
//
// A port whose span cannot be a parent and cannot be a child produces spans
// that are individually perfect and collectively useless.
type SpanFunc func(ctx context.Context, name string, attrs map[string]string) (context.Context, func(err error))

func noopSpan(ctx context.Context, _ string, _ map[string]string) (context.Context, func(error)) {
	return ctx, func(error) {}
}

// CommandOutcome is the final observable result of one Deposit/Withdraw
// call, returned to the caller alongside any error.
type CommandOutcome struct {
	State   domain.State
	Effects []domain.Effect
	// Stage names the last commandState transition this command reached.
	//
	// There is deliberately NO EffectsCommitted field. It used to report
	// whether delivery had succeeded, and once delivery moved to the relay
	// this layer cannot know that -- the honest options were to remove it or
	// to redefine it, and a field that silently changes meaning is worse than
	// one that is gone, because every existing reader keeps believing the old
	// meaning. Delivery progress is observable on the relay (its lag against
	// the log head), which is where it now happens.
	Stage string
}

// commandState names this orchestrator's state machine for processing ONE
// command (Deposit or Withdraw). Documented here, with each transition's
// crash-recovery semantics, per this zone's job: pure decision-making lives
// in internal/domain; RECOVERABLE ORCHESTRATION lives here.
//
//	Received   -- command accepted, nothing durable yet. Crash here:
//	              nothing happened; safe to retry from scratch.
//	Applied    -- domain.Apply executed against the current state and the
//	              runtime invariant checks have run. This decision is still
//	              IN MEMORY and the lock is still held; a crash here loses
//	              only the decision, which the caller may safely retry.
//	Logged     -- the event was admitted and appended to the durable
//	              EventJournal. Crash here: the log has the entry but
//	              in-memory state does not. Recovery: the composition root
//	              replays the journal through domain.Apply before building
//	              a Ledger, so the next process starts with it folded in.
//	Committed  -- in-memory state advanced to match the log, and the relay
//	              was nudged. Terminal.
//
// # Why decide, then journal, then commit -- all under ONE lock
//
// The order is load-bearing in both directions.
//
// Journaling FIRST (before Apply) would put commands into the log that the
// domain then rejects -- a duplicate, an overdraft, a malformed amount. The
// log would stop being a log of facts and become a log of attempts, and
// every reader of it (replay, the relay, an auditor) would have to
// re-implement admission to tell the two apart. The relay's mapper in
// particular cannot: admission depends on ACCUMULATED state, which is not
// in the event. Keeping only admitted events makes the log's contract
// "everything in here happened".
//
// Committing state before the append succeeds would let the service serve a
// balance that no durable record supports; a crash would then silently undo
// an acknowledged command.
//
// Holding ONE lock across all three closes the window between deciding and
// committing. Releasing it in between lets a concurrent command decide
// against a state that is about to change underneath it -- two withdrawals
// each reading the same balance, each individually valid, together
// overdrawing.
type commandState int

const (
	csReceived commandState = iota
	csApplied
	csLogged
	csCommitted
)

// String names the stage a command reached, for CommandOutcome.Stage --
// exported observability of the state machine documented above, not just
// an internal bookkeeping detail (a caller or test can distinguish "the
// command was rejected by the domain without ever reaching the log" from
// "the command was admitted and is durable").
func (s commandState) String() string {
	switch s {
	case csReceived:
		return "received"
	case csApplied:
		return "applied"
	case csLogged:
		return "logged"
	case csCommitted:
		return "committed"
	default:
		return "unknown"
	}
}

// Ledger is the orchestrator: it holds the current domain.State in memory,
// applies each command through the pure core, journals it durably if the
// core ADMITS it, and nudges the relay that publishes what the log gained.
type Ledger struct {
	mu    sync.Mutex
	state domain.State

	journal   EventJournal
	notify    Notifier
	clock     Clock
	ids       IDGenerator
	spanStart SpanFunc

	// Invariant counters -- mirrored to Prometheus by
	// internal/adapter/in/healthhttp (one series per ratified invariant,
	// tier-policy: invariant_counters required). Incremented ONLY when
	// checkConservation/checkIdempotency (see invariants.go) detect a real
	// mismatch; asserted to stay 0 under every normal-operation test and
	// asserted to increment under a deliberately violating direct call --
	// see invariants_test.go and verification/ratified/invariants_test.go.
	conservationViolations   atomic.Int64
	duplicateEffectViolation atomic.Int64
	lastViolationUnixNano    atomic.Int64
}

// NewLedger constructs a Ledger starting from initial (the state
// reconstructed by replaying the durable event journal at boot -- see
// internal/platform/eventlog.Rebuild). All five parameters are required:
// journal and effects are the durable/outbox ports, and clock/ids are the
// injected wall-clock/randomness ports -- this package never reads either
// ambiently (internal/architecture/boundaries_test.go's
// TestCoreWallClock_TimeNowBannedExceptAllowlist enforces the clock half
// mechanically), so there is deliberately no nil-defaulting fallback here:
// the composition root (cmd/<SERVICE>) always supplies
// internal/platform/clock.Real{}.Now and
// internal/platform/ids.Real{}.NewID explicitly, and every test in this
// package supplies its own deterministic fake.
func NewLedger(initial domain.State, journal EventJournal, notify Notifier, clock Clock, ids IDGenerator) *Ledger {
	if notify == nil {
		notify = func() {} // a Ledger with no relay attached still commands
	}
	return &Ledger{state: initial, journal: journal, notify: notify, clock: clock, ids: ids, spanStart: noopSpan}
}

// SetTracer wires a real tracing backend. fn matches
// observability.Tracer.StartSpan's shape adapted to app's own SpanFunc port
// (see the composition root for the adapter).
func (l *Ledger) SetTracer(fn SpanFunc) {
	if fn == nil {
		fn = noopSpan
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.spanStart = fn
}

// State returns a snapshot of the current ledger state.
func (l *Ledger) State() domain.State {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.state
}

// Deposit runs the full command pipeline for a deposit of amount, using
// eventID as the idempotency key if non-empty, or minting a fresh one via
// the injected IDGenerator otherwise.
func (l *Ledger) Deposit(ctx context.Context, eventID, amount string) (CommandOutcome, error) {
	return l.process(ctx, "svc.deposit", eventID, domain.EventDeposited, amount)
}

// Withdraw runs the full command pipeline for a withdrawal of amount.
func (l *Ledger) Withdraw(ctx context.Context, eventID, amount string) (CommandOutcome, error) {
	return l.process(ctx, "svc.withdraw", eventID, domain.EventWithdrawn, amount)
}

// process is the state machine documented on commandState: csReceived ->
// csApplied -> csLogged -> csCommitted, with the last three inside one
// critical section.
func (l *Ledger) process(ctx context.Context, spanName, eventID string, eventType domain.EventType, amount string) (CommandOutcome, error) {
	ctx, end := l.spanStart(ctx, spanName, map[string]string{"event_type": string(eventType)})
	var stepErr error
	defer func() { end(stepErr) }()

	if eventID == "" {
		eventID = l.ids()
	}
	event := domain.Event{ID: eventID, Type: eventType, Amount: amount}

	l.mu.Lock()

	// -- Received -> Applied ------------------------------------------------
	// Pure, in memory, still under the lock. Nothing is durable yet.
	before := l.state
	after, effectsOut := domain.Apply(before, event)
	l.checkInvariants(before, event, after)

	// domain.Apply increments Version exactly when it ADMITS the event, and
	// leaves it untouched for every rejection (duplicate, overdraft,
	// malformed amount, unknown type). That makes the version bump the
	// domain's own admission signal, so this layer does not have to
	// enumerate rejection effect types -- a new rejection added to the
	// domain is handled here without an edit, whereas a type switch would
	// silently start journaling it.
	admitted := after.Version > before.Version

	// -- Applied -> Logged ---------------------------------------------------
	if admitted {
		// ctx here is the SPAN's context, not the caller's: the journal
		// records its traceparent, so the relay's later publish of this very
		// record joins the trace this command opened.
		if err := l.journal.Append(ctx, event); err != nil {
			// State is NOT advanced: the decision dies with the append.
			l.mu.Unlock()
			stepErr = fmt.Errorf("app: journal append: %w", err)
			return CommandOutcome{State: before, Effects: effectsOut, Stage: csApplied.String()}, stepErr
		}
	}

	// -- Logged -> Committed -------------------------------------------------
	l.state = after
	l.mu.Unlock()

	// The write path ENDS here. The event is durable and the state is
	// folded; delivery is the relay's job, reached by a nudge that cannot
	// block. Publishing inline would put a network round trip inside the
	// command, so an unreachable broker would stop the service rather than
	// merely delay its notifications.
	//
	// Nudging only on admission keeps the relay from waking for commands
	// that appended nothing -- under a duplicate-heavy retry storm that is
	// the difference between a quiet relay and a hot spin.
	if admitted {
		l.notify()
	}

	return CommandOutcome{State: after, Effects: effectsOut, Stage: csCommitted.String()}, nil
}
