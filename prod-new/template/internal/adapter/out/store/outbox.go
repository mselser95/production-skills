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
	"sort"
	"sync"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/outboxlog"
)

// EntryState is an outbox entry's lifecycle stage.
type EntryState string

const (
	StateIntent    EntryState = "intent"
	StateDelivered EntryState = "delivered"
	StateFailed    EntryState = "failed" // exhausted MaxAttempts; a Reconcile candidate
	// StateDeadLettered is an entry evicted by a bound. It is NOT a delivery
	// outcome: the effect was never delivered and may well still be
	// deliverable. Reconcile ignores it, so it stops consuming the bound,
	// and Requeue is the explicit way back.
	StateDeadLettered EntryState = "dead_lettered"
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
	// JournaledAt is when the intent was accepted. Zero, with AgeKnown
	// false, for an entry replayed from a schema-1 record written before
	// the timestamp existed.
	JournaledAt time.Time
	// AgeKnown distinguishes "this entry is new" from "I cannot tell how
	// old this entry is". See outboxlog.Snapshot.AgeKnown.
	AgeKnown bool
}

// Clock reports the current time, mirroring internal/platform/clock.Clock.Now
// as a plain func so this package need not import it -- the same local-port
// idiom IDGenerator already uses.
type Clock func() time.Time

// Limits bound how much UNDELIVERED work the outbox may hold.
//
// Two bounds, because they protect different failures and neither implies
// the other:
//
//   - MaxPending bounds MEMORY. A fast producer against a dead sink piles up
//     entries that are all brand new, so an age bound would not fire until
//     long after the process died.
//   - MaxPendingAge bounds STALENESS. One entry stuck forever never trips a
//     count bound, and an ancient delivery that is finally resurrected lands
//     outside whatever dedup window the receiver keeps -- so it is stored
//     twice, which is the failure the idempotency key was supposed to
//     prevent.
//
// Zero means "use the default", never "unbounded": an outbox that grows
// without limit because nobody filled in a field is the defect this type
// exists to remove.
type Limits struct {
	MaxPending    int
	MaxPendingAge time.Duration
	// MaxRetained bounds the TOTAL in-memory entry map, evicting TERMINAL
	// entries (delivered, dead-lettered) oldest-first once it is exceeded.
	//
	// Bounding only the pending set would have left this outbox with its own
	// leak in two places: dead-lettered entries would accumulate forever as
	// the very bound that evicted them filled memory, and -- a leak that
	// predates any bound here -- every successfully DELIVERED entry was
	// retained for the life of the process, so a healthy high-throughput
	// service grew without limit precisely because nothing was going wrong.
	//
	// Evicting a terminal entry loses nothing: its transitions are already
	// in the durable log, which is the record. What it costs is the ability
	// to Entry() or Requeue() that id from memory afterwards.
	MaxRetained int
}

// Bound defaults. Deliberately generous: they are a backstop against
// unbounded growth, not a tuning knob, and a bound that evicts during normal
// operation would train operators to raise it until it is gone.
const (
	DefaultMaxPending    = 10_000
	DefaultMaxPendingAge = 24 * time.Hour
	// Ten pending sets' worth of history kept for inspection. Terminal
	// entries are cheap and useful to have around; they are simply not
	// allowed to be infinite.
	DefaultMaxRetained = 100_000
)

func (l Limits) withDefaults() Limits {
	if l.MaxPending <= 0 {
		l.MaxPending = DefaultMaxPending
	}
	if l.MaxPendingAge <= 0 {
		l.MaxPendingAge = DefaultMaxPendingAge
	}
	if l.MaxRetained <= 0 {
		l.MaxRetained = DefaultMaxRetained
	}
	if l.MaxRetained < l.MaxPending {
		// A retention bound below the pending bound would evict entries that
		// are still waiting to be delivered, which is the one thing neither
		// bound may ever do.
		l.MaxRetained = l.MaxPending
	}
	return l
}

// Option configures an Outbox at construction. Variadic options rather than
// more positional parameters, so adding a bound did not change either
// constructor's signature and every existing call site kept working -- while
// still getting the defaults.
type Option func(*Outbox)

// WithLimits sets the pending bounds.
func WithLimits(l Limits) Option { return func(o *Outbox) { o.limits = l.withDefaults() } }

// WithClock injects the clock used for entry ages.
func WithClock(c Clock) Option {
	return func(o *Outbox) {
		if c != nil {
			o.clock = c
		}
	}
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

// Outbox is the outbox implementation. Constructed via OpenDurable it
// journals every state transition to an append-only log and rebuilds its
// pending set from that log at boot; constructed via NewOutbox it keeps
// entries in memory only, which is a deliberate and separately-named choice
// rather than a default.
//
// It is BOUNDED (see Limits). An outbox without a bound is not a smaller
// problem than no outbox at all -- it is a queue that grows for exactly as
// long as the thing it feeds is broken, on a service that reports itself
// healthy throughout, because nothing about an unbounded queue looks wrong
// until the process dies. Entries evicted by a bound are dead-lettered:
// durable, listable, countable and requeueable, never dropped.
type Outbox struct {
	mu          sync.Mutex
	entries     map[string]*Entry
	sink        Sink
	ids         IDGenerator
	maxAttempts int
	// journal, when non-nil, makes every state transition durable. nil is
	// the explicitly-chosen non-durable form -- see NewOutbox vs
	// OpenDurable.
	journal *outboxlog.Log

	limits      Limits
	clock       Clock
	deadLetters int
	// compactions/compactedEntries/compactedBytes record what boot-time
	// compaction reclaimed from the durable log. COUNTERS, for the same
	// reason deadLetters is one: the thing they measure is a file that just
	// got SMALLER, so anything derived from the current size would read as
	// "nothing happened" precisely when the mechanism worked.
	//
	// They are the operational answer to "is the outbox log still bounded".
	// A compaction that silently stops reclaiming -- because every entry is
	// retained by the watermark guard, or because the rewrite keeps failing
	// -- looks exactly like a healthy service with nothing to reclaim, right
	// up until the volume fills. See CompactionStats.
	compactions      int
	compactedEntries int
	compactedBytes   int64
}

// NewOutbox constructs a NON-DURABLE Outbox: entries live in memory only, so
// a journaled-but-undelivered intent survives a sink outage but NOT a
// process restart.
//
// The name says so on purpose. This used to be the only constructor, which
// meant every service inherited an outbox that did not do the one thing the
// pattern exists for, by default and silently. Durability is now
// OpenDurable, and choosing this one is a visible decision in the
// composition root rather than a forgotten default -- which is also why it
// is a separate constructor and not a nil-able option on this one.
func NewOutbox(sink Sink, ids IDGenerator, maxAttempts int, opts ...Option) *Outbox {
	if maxAttempts <= 0 {
		maxAttempts = 5
	}
	o := &Outbox{
		entries:     map[string]*Entry{},
		sink:        sink,
		ids:         ids,
		maxAttempts: maxAttempts,
		limits:      Limits{}.withDefaults(),
		clock:       time.Now,
	}
	for _, opt := range opts {
		opt(o)
	}
	return o
}

// evictForBounds dead-letters whatever must go for the bounds to hold, and
// returns the ids evicted. Caller must NOT hold o.mu.
//
// Order is deliberate: stale first, then oldest-to-make-room. Doing it the
// other way could evict a fresh entry to make room while a week-old one sat
// beside it untouched.
func (o *Outbox) evictForBounds(headroom int) []string {
	now := o.clock()

	o.mu.Lock()
	pending := make([]*Entry, 0, len(o.entries))
	for _, e := range o.entries {
		if e.State == StateIntent || e.State == StateFailed {
			pending = append(pending, e)
		}
	}
	// Oldest first, deterministically. Map iteration order is random, and an
	// eviction rule that picks a different victim on every run is not a rule.
	// Unknown-age entries sort as oldest: they have survived at least one
	// restart, so they are the least likely to be the freshest thing here.
	sort.Slice(pending, func(i, j int) bool {
		a, b := pending[i], pending[j]
		if a.AgeKnown != b.AgeKnown {
			return !a.AgeKnown
		}
		if !a.JournaledAt.Equal(b.JournaledAt) {
			return a.JournaledAt.Before(b.JournaledAt)
		}
		return a.ID < b.ID
	})

	var victims []*Entry
	keep := pending[:0:0]
	for _, e := range pending {
		// Age bound applies only to entries whose age we actually know. An
		// entry replayed from schema 1 has no journaling time, and evicting
		// it on a guess would make a version bump look like an outage.
		if e.AgeKnown && now.Sub(e.JournaledAt) > o.limits.MaxPendingAge {
			victims = append(victims, e)
			continue
		}
		keep = append(keep, e)
	}
	// Count bound, leaving `headroom` slots free for the caller about to
	// journal.
	for len(keep) > o.limits.MaxPending-headroom && len(keep) > 0 {
		victims = append(victims, keep[0])
		keep = keep[1:]
	}
	// Retention bound: forget terminal entries, oldest first. They are
	// durable in the log; only the in-memory copy goes.
	var forget []string
	// headroom is reserved here too: without it the map settles at
	// MaxRetained+1, because eviction runs BEFORE Journal adds its entry and
	// a bound that is off by one is a bound that does not mean what it says.
	if len(o.entries)+headroom > o.limits.MaxRetained {
		terminal := make([]*Entry, 0, len(o.entries))
		for _, e := range o.entries {
			if e.State == StateDelivered || e.State == StateDeadLettered {
				terminal = append(terminal, e)
			}
		}
		sort.Slice(terminal, func(i, j int) bool {
			a, b := terminal[i], terminal[j]
			if !a.JournaledAt.Equal(b.JournaledAt) {
				return a.JournaledAt.Before(b.JournaledAt)
			}
			return a.ID < b.ID
		})
		over := len(o.entries) + headroom - o.limits.MaxRetained
		for i := 0; i < over && i < len(terminal); i++ {
			forget = append(forget, terminal[i].ID)
		}
	}
	for _, id := range forget {
		delete(o.entries, id)
	}
	o.mu.Unlock()

	var evicted []string
	for _, e := range victims {
		if err := o.record(outboxlog.Record{
			EntryID: e.ID, State: outboxlog.StateDeadLettered,
			IdempotencyKey: e.IdempotencyKey,
		}); err != nil {
			// Durable first. If the transition cannot be recorded the entry
			// stays pending: an in-memory-only eviction would vanish on the
			// next restart, resurrecting an effect the bound had retired.
			continue
		}
		o.mu.Lock()
		e.State = StateDeadLettered
		o.deadLetters++
		o.mu.Unlock()
		evicted = append(evicted, e.ID)
	}
	return evicted
}

// Journal durably records the intent to deliver effect and returns the new
// entry's id. Satisfies internal/app.EffectPublisher.Journal.
func (o *Outbox) Journal(effect domain.Effect) (string, error) {
	// Encode BEFORE accepting. An entry the durable format cannot represent
	// must not be journaled at all: returning an id for it would tell the
	// caller its intent is safe while a restart silently loses the effect.
	// This runs even in the non-durable form, so the two constructors cannot
	// disagree about what is acceptable.
	envelope, err := outboxlog.EncodeEffect(effect)
	if err != nil {
		return "", err
	}

	// Enforce the bounds BEFORE accepting, asking for one slot of headroom.
	// Doing it here rather than on a sweep means the invariant "pending never
	// exceeds MaxPending" holds at every observable moment, instead of being
	// true only between ticks of some background loop.
	o.evictForBounds(1)

	now := o.clock()
	o.mu.Lock()
	id := o.ids()
	// The idempotency key is minted HERE, once, and belongs to the ENTRY for
	// the rest of its life -- see the Entry.IdempotencyKey doc for why it
	// cannot be minted per-Publish.
	entry := &Entry{
		ID: id, Effect: effect, State: StateIntent, IdempotencyKey: o.ids(),
		JournaledAt: now, AgeKnown: true,
	}
	o.mu.Unlock()

	// Durable BEFORE in-memory. If the append fails the entry never existed,
	// which is the only honest outcome: an accepted intent that is not on
	// disk is exactly the loss this pattern exists to prevent.
	if err := o.record(outboxlog.Record{
		EntryID:             id,
		State:               outboxlog.StateIntent,
		IdempotencyKey:      entry.IdempotencyKey,
		Effect:              &envelope,
		JournaledAtUnixNano: now.UnixNano(),
	}); err != nil {
		return "", err
	}

	o.mu.Lock()
	o.entries[id] = entry
	o.mu.Unlock()
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
			attempts := entry.Attempts
			o.mu.Unlock()
			// Recorded AFTER the effect succeeded. A crash between the sink
			// accepting and this append leaves the entry pending, so
			// recovery re-delivers under the SAME key -- at-least-once with
			// a dedupable key, which is the guarantee this pattern can
			// actually offer. Recording it BEFORE would be a lie in the
			// other direction: an entry marked delivered that never was.
			_ = o.record(outboxlog.Record{
				EntryID: entryID, State: outboxlog.StateDelivered,
				IdempotencyKey: idempotencyKey, Attempts: attempts,
			})
			return nil
		}
		lastErr = err
	}

	o.mu.Lock()
	entry.State = StateFailed
	failedAttempts := entry.Attempts
	o.mu.Unlock()
	_ = o.record(outboxlog.Record{
		EntryID: entryID, State: outboxlog.StateFailed,
		IdempotencyKey: idempotencyKey, Attempts: failedAttempts,
	})
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

// OpenDurable constructs an Outbox whose every state transition is journaled
// to path before it is acted on, and whose pending entries are RECONSTRUCTED
// from that log at boot.
//
// This is the durable form of the outbox pattern: the point of journaling an
// intent before performing an effect is that a crash between the two leaves
// something to recover from, and that is only true if the journal outlives
// the process.
//
// Entries replayed in state delivered are kept rather than dropped: their
// idempotency key is the evidence an operator needs to correlate this
// service's record with what the receiver actually saw.
func OpenDurable(path string, sink Sink, ids IDGenerator, maxAttempts int, opts ...Option) (*Outbox, error) {
	records, err := outboxlog.Replay(path)
	if err != nil {
		return nil, err
	}
	snapshots, err := outboxlog.Rebuild(records)
	if err != nil {
		return nil, err
	}
	log, err := outboxlog.Open(path)
	if err != nil {
		return nil, err
	}
	o := NewOutbox(sink, ids, maxAttempts, opts...)
	o.journal = log
	for _, snap := range snapshots {
		e := &Entry{
			ID:             snap.EntryID,
			Effect:         snap.Effect,
			State:          EntryState(snap.State),
			Attempts:       snap.Attempts,
			IdempotencyKey: snap.IdempotencyKey,
			AgeKnown:       snap.AgeKnown,
		}
		if snap.AgeKnown {
			// Restored from the ORIGINAL journaling time, not from now. This
			// is the whole point of persisting it: an entry stamped at boot
			// comes back looking freshly journaled, so an age bound would
			// reset on every restart and a crash-looping service would never
			// evict anything.
			e.JournaledAt = time.Unix(0, snap.JournaledAtUnixNano)
		}
		if e.State == StateDeadLettered {
			o.deadLetters++
		}
		o.entries[snap.EntryID] = e
	}
	return o, nil
}

// Close closes the durable journal, if there is one.
func (o *Outbox) Close() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.journal == nil {
		return nil
	}
	return o.journal.Close()
}

// Compact reclaims the durable log, folding away every entry that reached a
// terminal state and whose IDENTITY retain declines to keep. It returns what
// the rewrite did.
//
// CALL THIS AT BOOT, and only at boot. The log was append-only with no
// compaction, so it grew with total lifetime effect volume rather than with
// the live set, and OpenDurable's replay grew with it -- reading the whole
// delivery history of the service to reconstruct a working set that is
// usually empty. That is registries/contract-debt.yaml's
// outbox-log-grows-without-compaction, and this is its payment.
//
// WHY BOOT AND NOT A TICKER. Compaction rewrites the file under the open
// handle; outboxlog.Compact serializes that against Append, so a concurrent
// Journal is safe from the FILE's point of view. What it is not safe from is
// the WATERMARK's: retain must describe every identity the boot rebuild can
// still re-derive from the event log, and that set is only knowable while the
// rebuild is the thing running. Running this on a timer would mean computing
// that set against an event log that has moved, which is how a compaction
// starts republishing history.
//
// RETAIN IS KEYED ON IDENTITY, NOT ON THE ENTRY ID, and that is the one thing
// this method adds over outboxlog.Compact. Journal mints an opaque entry id
// and a separate idempotency key; JournalDerived mints an opaque entry id and
// stores the CALLER'S identity as the key. KnowsIdentity -- the watermark the
// boot rebuild consults -- matches on the key. So the caller answers about
// identities and this method translates. An entry with NO idempotency key is
// offered as not-re-derivable: nothing can ever match it through
// KnowsIdentity, so it is a watermark for nothing.
//
// A NON-DURABLE outbox has nothing on disk to compact, so this reports a zero
// result rather than an error: the caller should not have to know which
// constructor built it.
func (o *Outbox) Compact(retain func(identity string) bool) (outboxlog.CompactStats, error) {
	o.mu.Lock()
	journal := o.journal
	o.mu.Unlock()
	if journal == nil {
		return outboxlog.CompactStats{}, nil
	}

	// Deliberately NOT holding o.mu across the rewrite. retain is supplied by
	// the composition root and, in a future where it consults something other
	// than a plain map, calling it under this mutex would be a lock-ordering
	// trap for a mechanism that has no need of the mutex at all: the log has
	// its own.
	stats, err := journal.Compact(func(_ string, idempotencyKey string) bool {
		if retain == nil || idempotencyKey == "" {
			return false
		}
		return retain(idempotencyKey)
	})
	if err != nil {
		return stats, err
	}

	o.mu.Lock()
	defer o.mu.Unlock()
	o.compactions++
	o.compactedEntries += stats.EntriesDropped()
	o.compactedBytes += stats.BytesReclaimed()
	return stats, nil
}

// CompactionStats reports what compaction has reclaimed for the lifetime of
// this process: how many times it ran, how many entries it dropped, and how
// many bytes it gave back.
//
// Exposed as an accessor rather than kept internal because these are the
// three numbers the metrics surface needs, and a mechanism whose effect
// nothing can observe is one nobody notices has stopped working -- the same
// defect as a dead-letter store with no counter.
func (o *Outbox) CompactionStats() (runs, entriesDropped int, bytesReclaimed int64) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.compactions, o.compactedEntries, o.compactedBytes
}

// record appends one state transition to the durable journal, if there is
// one. Callers hold no lock: outboxlog.Log has its own.
func (o *Outbox) record(rec outboxlog.Record) error {
	if o.journal == nil {
		return nil
	}
	return o.journal.Append(rec)
}

// DeadLettered returns every entry a bound evicted. They are durable and
// auditable: an eviction that could not be listed would be a deletion with
// extra steps.
func (o *Outbox) DeadLettered() []Entry {
	o.mu.Lock()
	defer o.mu.Unlock()
	var out []Entry
	for _, e := range o.entries {
		if e.State == StateDeadLettered {
			out = append(out, *e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// DeadLetterCount returns how many entries bounds have evicted over this
// outbox's life, including any replayed from the journal.
func (o *Outbox) DeadLetterCount() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.deadLetters
}

// PendingStats summarises the undelivered backlog: how many entries are
// waiting, how old the oldest one whose age is KNOWN is, and how many have
// an age nobody can state.
//
// unknownAge is reported separately rather than folded into oldestAge
// because the two support opposite conclusions. "The oldest pending entry is
// 5 seconds old" and "I cannot tell you how old anything here is" are
// different claims, and a single number that quietly means both is a metric
// that reassures precisely when it should not.
func (o *Outbox) PendingStats() (count int, oldestAge time.Duration, unknownAge int) {
	now := o.clock()
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, e := range o.entries {
		if e.State != StateIntent && e.State != StateFailed {
			continue
		}
		count++
		if !e.AgeKnown {
			unknownAge++
			continue
		}
		if age := now.Sub(e.JournaledAt); age > oldestAge {
			oldestAge = age
		}
	}
	return count, oldestAge, unknownAge
}

// ErrNotDeadLettered is returned by Requeue for an entry that is not in
// StateDeadLettered.
var ErrNotDeadLettered = errors.New("store: entry is not dead-lettered")

// Requeue returns a dead-lettered entry to the pending set so a later
// Reconcile will attempt it again.
//
// Deliberately manual. Nothing requeues automatically, because an automatic
// path would defeat the bound it just enforced: the entry would be evicted,
// requeued, evicted again, forever. This is the operator's answer to "the
// sink was down for a day, I want that work back", and its existence is what
// makes dead-lettering a pause rather than a deletion.
//
// The idempotency key survives, so a requeued delivery is still the SAME
// logical effect to any receiver that dedupes -- though note that if the
// entry has been sitting longer than that receiver's dedup window, the key
// no longer helps, which is the reason the age bound exists at all.
func (o *Outbox) Requeue(id string) error {
	o.mu.Lock()
	entry, ok := o.entries[id]
	if !ok {
		o.mu.Unlock()
		return fmt.Errorf("store: unknown outbox entry %q", id)
	}
	if entry.State != StateDeadLettered {
		o.mu.Unlock()
		return fmt.Errorf("%w: %q is %q", ErrNotDeadLettered, id, entry.State)
	}
	key := entry.IdempotencyKey
	o.mu.Unlock()

	// Durable before in-memory, as everywhere else here: a requeue that only
	// happened in memory would un-happen on the next restart, and the entry
	// would be dead-lettered again with no record of the operator's decision.
	if err := o.record(outboxlog.Record{
		EntryID: id, State: outboxlog.StateIntent, IdempotencyKey: key,
	}); err != nil {
		return err
	}
	o.mu.Lock()
	entry.State = StateIntent
	o.mu.Unlock()
	return nil
}

// JournalDerived accepts an effect under a caller-supplied IDENTITY rather
// than a minted id, and is idempotent on it: journaling the same identity
// twice records the intent once.
//
// It exists for the boot-time reconstruction that closes the window between
// the state commit and the effect journal (see internal/app's
// effect_identity.go). A crash in that window leaves an event that replays and
// an effect that was never journaled; recovery re-derives the effect from the
// event log and offers it here. Offering one that WAS already journaled must
// be a no-op, or every restart would redeliver the entire deliverable history.
//
// The identity IS the idempotency key, deliberately. A recovered effect has to
// present the key its first attempt would have presented, or a resumed
// delivery arrives at the sink as a brand-new one and the deduplication that
// makes at-least-once tolerable does nothing.
func (o *Outbox) JournalDerived(identity string, effect domain.Effect) (string, error) {
	if identity == "" {
		return "", errors.New("store: JournalDerived requires a non-empty identity")
	}

	// Already known? Then this is a recovery pass re-offering something the
	// log already has, and the honest answer is the existing entry.
	o.mu.Lock()
	for id, e := range o.entries {
		if e.IdempotencyKey == identity {
			o.mu.Unlock()
			return id, nil
		}
	}
	o.mu.Unlock()

	envelope, err := outboxlog.EncodeEffect(effect)
	if err != nil {
		return "", err
	}
	o.evictForBounds(1)

	now := o.clock()
	o.mu.Lock()
	id := o.ids()
	entry := &Entry{
		ID: id, Effect: effect, State: StateIntent, IdempotencyKey: identity,
		JournaledAt: now, AgeKnown: true,
	}
	o.mu.Unlock()

	if err := o.record(outboxlog.Record{
		EntryID:             id,
		State:               outboxlog.StateIntent,
		IdempotencyKey:      identity,
		Effect:              &envelope,
		JournaledAtUnixNano: now.UnixNano(),
	}); err != nil {
		return "", err
	}

	o.mu.Lock()
	o.entries[id] = entry
	o.mu.Unlock()
	return id, nil
}

// KnowsIdentity reports whether an entry with this identity has ever been
// journaled -- in any state, including delivered and dead-lettered.
//
// "In any state" is the load-bearing part. A DELIVERED entry must still be
// recognised, or the boot-time reconstruction would re-journal effects the
// sink already received and turn every restart into a redelivery storm.
// OpenDurable keeps delivered entries for exactly this reason.
func (o *Outbox) KnowsIdentity(identity string) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, e := range o.entries {
		if e.IdempotencyKey == identity {
			return true
		}
	}
	return false
}
