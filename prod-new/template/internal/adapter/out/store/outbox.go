// Package store is the DRIVEN (out) adapter for this service's one
// external_effect capability: delivering a notification of every admitted
// ledger effect (EffectDeposited/EffectWithdrawn) to something outside this
// process, via the OUTBOX pattern.
//
// The pattern, exactly as internal/app.EffectPublisher's doc describes it:
//
//  1. Journal(effect)  -- durably record the INTENT to deliver, before any
//     network call is attempted. Returns an opaque entry id.
//  2. Publish(ctx, id) -- attempt delivery via the configured Sink, with
//     retry. The idempotency key handed to Sink.Deliver is generated ONCE,
//     INSIDE the retry closure (see (*Outbox).Publish) -- not by the
//     caller, and not regenerated on every physical retry attempt, so a
//     downstream system doing its own dedup sees the SAME key across
//     however many attempts one logical Publish call makes.
//  3. Mark done -- on a successful Deliver, the entry moves to
//     StateDelivered and Reconcile (below) will never touch it again.
//
// A crash between steps 1 and 2 leaves a durable, RECOVERABLE intent: the
// entry sits in StateIntent until a future Reconcile call resumes delivery
// -- the ledger's own domain state is already final by the time Journal is
// even called (see internal/app.Ledger.process), so recovery here is purely
// about the side notification, never about the money.
package store

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// EntryState is an outbox entry's lifecycle stage.
type EntryState string

const (
	StateIntent    EntryState = "intent"
	StateDelivered EntryState = "delivered"
	StateFailed    EntryState = "failed" // exhausted MaxAttempts; a Reconcile candidate
)

// Entry is one outbox record.
type Entry struct {
	ID       string
	Effect   domain.Effect
	State    EntryState
	Attempts int
	// IdempotencyKey identifies this ENTRY's logical delivery, for the
	// entry's whole life. Minted by Journal, never re-minted: it is the
	// only thing that lets a receiver collapse repeated deliveries of the
	// SAME effect into one, and "the same effect" is an entry, not a call.
	IdempotencyKey string
}

// Sink is the external system this outbox delivers to. The template ships
// LogSink (see log_sink.go) as a real, working, dependency-free default;
// swap in a real HTTP/webhook/queue implementation without touching Outbox.
type Sink interface {
	// Deliver attempts one delivery attempt of entry, identified by
	// idempotencyKey so the receiving system can collapse retried attempts
	// of the SAME logical delivery into one effect.
	Deliver(ctx context.Context, idempotencyKey string, entry Entry) error
}

// IDGenerator mirrors internal/app.IDGenerator's shape so Outbox does not
// need to import internal/app (forbidden: internal/architecture/
// boundaries_test.go's TestAdapterOut_ForbidsAppAndAdapterIn) to describe
// the same injected-randomness port it also depends on.
type IDGenerator func() string

var errMaxAttemptsExhausted = errors.New("store: max delivery attempts exhausted")

// Outbox is the in-process outbox implementation. It is durable only for
// the lifetime of this process (an in-memory map) -- this template's
// composition root wires it against LogSink to demonstrate the full
// pattern end to end without requiring a real external dependency; a
// production fork backs Entry storage with the same durable
// internal/platform/eventlog-style append-only log the ledger itself uses,
// and swaps Sink for a real HTTP/queue client. See production.yaml's
// effect_journal_outbox decline for the precise scope line.
type Outbox struct {
	mu          sync.Mutex
	entries     map[string]*Entry
	sink        Sink
	ids         IDGenerator
	maxAttempts int
}

// NewOutbox constructs an Outbox delivering through sink, minting entry ids
// via ids, retrying each entry up to maxAttempts times.
func NewOutbox(sink Sink, ids IDGenerator, maxAttempts int) *Outbox {
	if maxAttempts <= 0 {
		maxAttempts = 5
	}
	return &Outbox{entries: map[string]*Entry{}, sink: sink, ids: ids, maxAttempts: maxAttempts}
}

// Journal durably records the intent to deliver effect and returns the new
// entry's id. Satisfies internal/app.EffectPublisher.Journal.
func (o *Outbox) Journal(effect domain.Effect) (string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	id := o.ids()
	// The idempotency key is minted HERE, once, and belongs to the ENTRY for
	// the rest of its life -- see the Entry.IdempotencyKey doc for why it
	// cannot be minted per-Publish.
	o.entries[id] = &Entry{ID: id, Effect: effect, State: StateIntent, IdempotencyKey: o.ids()}
	return id, nil
}

// Publish attempts delivery of the entry identified by entryID, retrying up
// to o.maxAttempts times with the SAME idempotency key across every retry
// (minted once, lazily, the first time the closure runs -- INSIDE the
// closure the retry loop calls, never before it). Satisfies
// internal/app.EffectPublisher.Publish.
func (o *Outbox) Publish(ctx context.Context, entryID string) error {
	o.mu.Lock()
	entry, ok := o.entries[entryID]
	o.mu.Unlock()
	if !ok {
		return fmt.Errorf("store: unknown outbox entry %q", entryID)
	}

	// The key comes from the ENTRY. It is deliberately NOT minted here.
	//
	// This code used to mint a fresh key per Publish invocation, and argued
	// in a comment that doing so "protects" the crash case: a new process
	// re-publishing the same entry would get its own key. That is backwards.
	// An idempotency key exists so the RECEIVER can recognise a repeat of the
	// same logical effect; a fresh key tells it the opposite, so the retry
	// that follows an ambiguous failure is guaranteed to double-deliver --
	// precisely when you cannot know whether the sink already had it.
	//
	// No crash is needed to see it. Reconcile calls Publish afresh for every
	// pending entry, so under the old code each recovery pass re-keyed and
	// defeated deduplication on an ordinary retry. Measured before the fix:
	// one effect, delivered across a failed Publish and one Reconcile, showed
	// the sink keys [id-2 id-2 id-3] -- correct within a call, wrong across
	// them.
	o.mu.Lock()
	idempotencyKey := entry.IdempotencyKey
	o.mu.Unlock()

	var lastErr error
	for attempt := 1; attempt <= o.maxAttempts; attempt++ {
		o.mu.Lock()
		entry.Attempts++
		snapshot := *entry
		o.mu.Unlock()
		snapshot.IdempotencyKey = idempotencyKey

		err := o.sink.Deliver(ctx, idempotencyKey, snapshot)
		if err == nil {
			o.mu.Lock()
			entry.State = StateDelivered
			o.mu.Unlock()
			return nil
		}
		lastErr = err
	}

	o.mu.Lock()
	entry.State = StateFailed
	o.mu.Unlock()
	return fmt.Errorf("store: entry %q: %w after %d attempts: %v", entryID, errMaxAttemptsExhausted, o.maxAttempts, lastErr)
}

// Entry returns a snapshot of one entry, for tests and for Reconcile's own
// use.
func (o *Outbox) Entry(id string) (Entry, bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	e, ok := o.entries[id]
	if !ok {
		return Entry{}, false
	}
	return *e, true
}

// Pending returns every entry currently sitting in StateIntent or
// StateFailed -- the exact "journal says X, world says Y" recovery
// candidates Reconcile resumes.
func (o *Outbox) Pending() []Entry {
	o.mu.Lock()
	defer o.mu.Unlock()
	var out []Entry
	for _, e := range o.entries {
		if e.State == StateIntent || e.State == StateFailed {
			out = append(out, *e)
		}
	}
	return out
}

// ReconcileResult is what one Reconcile pass accomplished.
type ReconcileResult struct {
	Resumed   int
	Delivered int
	StillDown int
}

// Reconcile drives every StateIntent/StateFailed entry through Publish
// again. This is the recovery function the outbox pattern requires: a
// process that crashed between Journal and Publish (or whose Publish
// exhausted its attempts while the sink was down) leaves entries exactly
// where Reconcile finds them, and calling it -- on a timer, or once at
// boot, in a production fork -- is what resumes them. It is intentionally
// table-driven over entry STATE (the "journal says X" half of the
// contract) rather than trying to ask the sink "did you already receive
// this?" (the "world says Y" half), because Sink.Deliver's OWN idempotency
// key is what makes a resumed delivery safe even if the sink actually did
// receive a prior attempt whose success response was lost -- Reconcile's
// job is only to make sure delivery is ATTEMPTED again, not to resolve the
// ambiguity itself.
func (o *Outbox) Reconcile(ctx context.Context) ReconcileResult {
	pending := o.Pending()
	result := ReconcileResult{Resumed: len(pending)}
	for _, e := range pending {
		if err := o.Publish(ctx, e.ID); err != nil {
			result.StillDown++
			continue
		}
		result.Delivered++
	}
	return result
}
