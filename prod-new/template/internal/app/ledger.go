// Package app is the durable orchestration zone: it drives
// internal/domain's pure Apply function through a real command-processing
// pipeline with an injected clock/id source, a durable event journal, and
// an outbox for effects that need external delivery.
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
type EventJournal interface {
	Append(event domain.Event) error
}

// EffectPublisher is the outbox port for effects requiring delivery to
// something outside this process. Satisfied structurally by
// internal/adapter/out/store.(*Outbox).
//
// Journal records the intent to deliver effect and returns an opaque entry
// id; Publish attempts delivery for a previously journaled entry and marks
// it done on success. Splitting these two steps -- rather than one
// "DeliverEffect" call -- is the outbox pattern itself: a crash between
// Journal and Publish leaves a durable, recoverable intent instead of a
// lost effect.
type EffectPublisher interface {
	Journal(effect domain.Effect) (entryID string, err error)
	Publish(ctx context.Context, entryID string) error
}

// Tracer is the narrow tracing port app needs, satisfied structurally by
// internal/platform/observability.Tracer without importing that package.
// A Ledger built without SetTracer uses noopSpan below, so tracing is
// additive and costs nothing by default.
type SpanFunc func(name string, attrs map[string]string) func(err error)

func noopSpan(string, map[string]string) func(error) { return func(error) {} }

// CommandOutcome is the final observable result of one Deposit/Withdraw
// call, returned to the caller alongside any error.
type CommandOutcome struct {
	State   domain.State
	Effects []domain.Effect
	// EffectsCommitted is true iff every EffectDeposited/EffectWithdrawn
	// effect this command produced was successfully journaled AND published
	// through the EffectPublisher. false does not mean the LEDGER state is
	// wrong -- the domain.Apply step (Logged/Applied below) already
	// committed durably before any effect publishing is attempted -- it
	// means the outbound notification is still pending in the outbox and
	// will be retried by a future Reconcile call.
	EffectsCommitted bool
	// Stage names the LAST commandState transition this command actually
	// reached (see the commandState doc above) -- "committed" is the only
	// terminal stage with EffectsCommitted=true; every other value pairs
	// with EffectsCommitted=false and names exactly where recovery should
	// resume from.
	Stage string
}

// commandState names this orchestrator's state machine for processing ONE
// command (Deposit or Withdraw). Documented here, with each transition's
// crash-recovery semantics, per this zone's job: pure decision-making lives
// in internal/domain; RECOVERABLE ORCHESTRATION lives here.
//
//	Received          -- command accepted, nothing durable yet.
//	                     Crash here: nothing happened; safe to retry from
//	                     scratch (no partial effect exists).
//	Logged            -- domain.Event appended to the durable EventJournal.
//	                     Crash here: the event log has the entry but
//	                     in-memory Ledger.state does not yet reflect it.
//	                     Recovery: cmd/<SERVICE>'s boot sequence replays the
//	                     journal through domain.Apply BEFORE constructing a
//	                     new Ledger, so the next process's initial state
//	                     already includes this entry -- no data loss, no
//	                     double-apply (domain.Apply's own idempotency-by-ID
//	                     guard covers a re-delivered command whose caller
//	                     retries with the same event ID).
//	Applied           -- domain.Apply executed; Ledger.state updated in
//	                     memory and the runtime invariant checks
//	                     (checkConservation) have run. Crash here: identical
//	                     to Logged's recovery (replay reconstructs the same
//	                     state, since Apply is deterministic).
//	EffectsJournaled  -- every Effect requiring external delivery has an
//	                     outbox intent (EffectPublisher.Journal). Crash
//	                     here: the intent is durable in the outbox; a
//	                     future Reconcile call resumes delivery from there
//	                     -- the ledger's own state is already final and
//	                     correct, only the SIDE NOTIFICATION is pending.
//	Committed         -- every journaled effect was Published successfully.
//	                     Terminal; no recovery needed.
type commandState int

const (
	csReceived commandState = iota
	csLogged
	csApplied
	csEffectsJournaled
	csCommitted
)

// String names the stage a command reached, for CommandOutcome.Stage --
// exported observability of the state machine documented above, not just
// an internal bookkeeping detail (a caller or test can distinguish "the
// ledger committed but a notification is still pending reconciliation"
// from "the ledger itself never committed" instead of inferring it from
// EffectsCommitted alone).
func (s commandState) String() string {
	switch s {
	case csReceived:
		return "received"
	case csLogged:
		return "logged"
	case csApplied:
		return "applied"
	case csEffectsJournaled:
		return "effects_journaled"
	case csCommitted:
		return "committed"
	default:
		return "unknown"
	}
}

// Ledger is the orchestrator: it holds the current domain.State in memory,
// journals every command durably before admitting it, applies it through
// the pure core, and drives any resulting effects through the outbox.
type Ledger struct {
	mu    sync.Mutex
	state domain.State

	journal   EventJournal
	effects   EffectPublisher
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
func NewLedger(initial domain.State, journal EventJournal, effects EffectPublisher, clock Clock, ids IDGenerator) *Ledger {
	return &Ledger{state: initial, journal: journal, effects: effects, clock: clock, ids: ids, spanStart: noopSpan}
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
// csLogged -> csApplied -> csEffectsJournaled -> csCommitted.
func (l *Ledger) process(ctx context.Context, spanName, eventID string, eventType domain.EventType, amount string) (CommandOutcome, error) {
	end := l.spanStart(spanName, map[string]string{"event_type": string(eventType)})
	var stepErr error
	defer func() { end(stepErr) }()

	if eventID == "" {
		eventID = l.ids()
	}
	event := domain.Event{ID: eventID, Type: eventType, Amount: amount}

	// -- Received -> Logged ------------------------------------------------
	// A failure here means the command never advanced past csReceived: it
	// is reported at that stage explicitly (Stage below), rather than the
	// zero-value CommandOutcome leaving the caller to guess how far the
	// pipeline got.
	if err := l.journal.Append(event); err != nil {
		stepErr = fmt.Errorf("app: journal append: %w", err)
		return CommandOutcome{Stage: csReceived.String()}, stepErr
	}
	// csLogged is reached here implicitly: nothing between a successful
	// journal append and the (infallible, pure) domain.Apply call below can
	// fail, so there is no observable stage between the two worth a
	// separate branch -- see commandState's own doc for the full
	// transition table this collapses.

	// -- Applied -------------------------------------------------------
	l.mu.Lock()
	before := l.state
	after, effectsOut := domain.Apply(before, event)
	l.checkInvariants(before, event, after)
	l.state = after
	l.mu.Unlock()

	// -- EffectsJournaled / Committed ---------------------------------------
	committed := true
	anyEffectJournaled := false
	for _, effect := range effectsOut {
		switch effect.(type) {
		case domain.EffectDeposited, domain.EffectWithdrawn:
			entryID, err := l.effects.Journal(effect)
			if err != nil {
				committed = false
				continue
			}
			anyEffectJournaled = true
			if err := l.effects.Publish(ctx, entryID); err != nil {
				committed = false
				continue
			}
		}
	}
	stage := csApplied
	if anyEffectJournaled {
		stage = csEffectsJournaled
	}
	if committed {
		stage = csCommitted
	}

	return CommandOutcome{State: after, Effects: effectsOut, EffectsCommitted: committed, Stage: stage.String()}, nil
}
