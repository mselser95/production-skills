// Package relay publishes committed events from the event log to a message
// bus. THE EVENT LOG IS THE OUTBOX: nothing is published that is not
// committed, and everything committed is published at least once, in order.
//
// # Why there is no separate outbox
//
// The obvious design is a second durable store holding "effects to deliver",
// written alongside the event. That design has an atomicity hole that is easy
// to miss and expensive to find: two stores, two writes, and no transaction
// between them. A crash in that window leaves an event committed whose effect
// was never recorded and never will be — a fact the system acted on that the
// outside world never hears about, with nothing anywhere saying so.
//
// The usual patch is to reconstruct the missing effects at boot by re-deriving
// them from the log and diffing against a delivery watermark. That works, and
// it is strictly more machinery than the problem needs: if the effects are
// derivable from the log, the log already IS the outbox and the second store
// was never carrying information. Deleting it removes the window rather than
// compensating for it.
//
// What remains is a position. The relay tails the log from a checkpoint, maps
// each event to zero or more publications, publishes them, and only then
// advances the checkpoint. One durable write on the write path; the relay is
// a reader.
//
// Design absorbed from clcsolutions/clc-go's pkg/es/relay (Facundo Diaz),
// whose decision table is the source for the publish-before-checkpoint rule
// and the leader-election shape below. Reimplemented rather than imported so
// this template stays dependency-free; the reasoning travels with it because
// the reasoning is the part that stops someone undoing it.
//
// # Reliability model
//
//   - Publish is SYNCHRONOUS. The checkpoint advances only after the broker
//     confirmed the message. A crash between publish and checkpoint means
//     REDELIVERY, never loss — consumers deduplicate on Message.ID.
//   - Message.ID is the persisted event ID, stable across redeliveries. A
//     freshly minted id per attempt would tell the receiver that a resumed
//     delivery is a brand-new fact, which is exactly the deduplication it
//     exists to enable.
//   - Exactly one replica relays per name, delegated to a Leader. The
//     template ships NopLeader; a multi-replica deployment supplies a real
//     one (see the Leader doc for the overlap this design tolerates).
package relay

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"
)

// Message is the transport-agnostic outgoing message.
type Message struct {
	// ID is the persisted event ID. It is STABLE across redeliveries, which
	// is what lets a consumer deduplicate: a retry after an ambiguous
	// failure must present the identity its first attempt had, or the
	// receiver has no way to recognize it as the same fact.
	ID string
	// Payload is the serialized event: the integration contract bytes and
	// nothing else. Envelope data belongs in Metadata, where brokers map it
	// to headers that middlewares and CLI tooling can read without
	// unmarshaling a payload whose schema they may not have.
	Payload []byte
	// Metadata becomes transport headers.
	Metadata map[string]string
}

// Publication is a mapped event ready to publish.
type Publication struct {
	Topic string
	Msg   Message
}

// Mapper turns a stored event into publications. Returning nil skips the
// event, which is the normal case for facts that never leave the service.
//
// This is where DOMAIN events become INTEGRATION events, and the distinction
// is load-bearing. Domain events are internal and may be refactored freely.
// Integration events are a published contract other people parse; renaming a
// field there breaks consumers you cannot deploy. Keeping the translation in
// one function means the boundary is a place, not a convention.
type Mapper[E Sequenced] func(e E) ([]Publication, error)

// Publisher sends one message and returns only after the broker CONFIRMED
// it.
//
// Implementations MUST NOT buffer asynchronously and report success. An async
// fire-and-forget publisher lets the relay checkpoint past messages the broker
// never received, converting a crash into silent, permanent loss — the exact
// failure this ordering exists to prevent.
type Publisher interface {
	Publish(ctx context.Context, topic string, msg Message) error
}

// CheckpointStore persists the relay position.
//
// Set must be durable before it returns. A checkpoint that survives in memory
// but not on disk turns every restart into a full republish of history, which
// downstream sees as a flood of duplicates.
type CheckpointStore interface {
	Get(ctx context.Context, name string) (int64, error)
	Set(ctx context.Context, name string, position int64) error
}

// Reader is the log's tail surface: the relay's half of the event store port.
//
// ReadAfter must be GAP-SAFE — it must never return an event at position N
// while an event at a position below N may still become visible. An
// append-only file written by a single writer satisfies this by construction,
// which is why this template's implementation needs no locking. A store with
// independently-committing writers does NOT: Postgres sequences are handed out
// before commit, so a naive `WHERE seq > $1 ORDER BY seq` can hand a reader
// position 7 while 6 is still in flight, and 6 is then skipped forever. Any
// replacement store must prove gap-safety against the contract suite before it
// is wired here.
type Reader[E Sequenced] interface {
	// ReadAfter returns up to limit events with position > after, in
	// position order.
	ReadAfter(ctx context.Context, after int64, limit int) ([]E, error)
	// Head returns the highest committed position (0 when empty).
	Head(ctx context.Context) (int64, error)
}

// Sequenced is an event that knows its own position in the log.
//
// The position travels WITH the event rather than beside it: a wrapper pairing
// the two can be built with a mismatched pair, and the checkpoint written from
// it would then name a position the published event never had.
type Sequenced interface {
	Position() int64
}

// Leader serializes relays across replicas. Acquire blocks until this process
// may run; lost closes if leadership is subsequently lost.
//
// A real implementation cannot make the handover instantaneous: loss is
// detected by observing something (a dead connection, an expired lease), so
// there is always a window in which an old holder still believes it leads
// while a new one is already running. That window is TOLERATED here rather
// than eliminated, and it is the reason the relay is at-least-once with
// stable message IDs: a brief dual-leader overlap produces duplicates, which
// consumers already deduplicate, instead of loss or reordering.
type Leader interface {
	Acquire(ctx context.Context) (release func(), lost <-chan struct{}, err error)
}

type nopLeader struct{}

func (nopLeader) Acquire(context.Context) (func(), <-chan struct{}, error) {
	return func() {}, nil, nil
}

// NopLeader always acquires and never loses. Correct for a single-replica
// deployment and for tests; wiring it with several replicas running means
// every replica publishes every event.
func NopLeader() Leader { return nopLeader{} }

// ErrLeadershipLost is returned by Run when the Leader reports the slot was
// lost. Restart Run to re-elect.
var ErrLeadershipLost = errors.New("relay: leadership lost")

// ErrRunning is returned when Run is called while this relay is already
// active in this process.
var ErrRunning = errors.New("relay: already running")

// Options configures a Relay.
type Options struct {
	// Name identifies this relay's checkpoint and leadership slot.
	Name string
	// Batch bounds how many events one read may return. Bounded because an
	// unbounded read of a long log is an out-of-memory waiting for a service
	// that has been running a while.
	Batch int
	// Idle is how long to wait after a read that returned nothing.
	Idle time.Duration
}

func (o *Options) withDefaults() {
	if o.Name == "" {
		o.Name = "relay"
	}
	if o.Batch <= 0 {
		o.Batch = 256
	}
	if o.Idle <= 0 {
		o.Idle = 250 * time.Millisecond
	}
}

// Relay publishes events for one named position.
type Relay[E Sequenced] struct {
	opts   Options
	reader Reader[E]
	cps    CheckpointStore
	mapper Mapper[E]
	pub    Publisher
	leader Leader

	running atomic.Bool
	wake    chan struct{}

	published atomic.Int64
	skipped   atomic.Int64
	batches   atomic.Int64
}

// New builds a Relay. Every collaborator is required: a relay with a nil
// publisher or checkpoint store would advance silently past events, which is
// the failure mode this package exists to make impossible.
func New[E Sequenced](reader Reader[E], cps CheckpointStore, mapper Mapper[E], pub Publisher, leader Leader, opts Options) (*Relay[E], error) {
	if reader == nil || cps == nil || mapper == nil || pub == nil {
		return nil, errors.New("relay: reader, checkpoint store, mapper and publisher are all required")
	}
	if leader == nil {
		leader = NopLeader()
	}
	opts.withDefaults()
	return &Relay[E]{
		opts:   opts,
		reader: reader,
		cps:    cps,
		mapper: mapper,
		pub:    pub,
		leader: leader,
		wake:   make(chan struct{}, 1),
	}, nil
}

// Notify tells the relay that new events may be available, so a healthy
// deployment does not wait out the idle interval before delivering.
//
// It never blocks. A full channel means a drain is already queued, which is
// exactly when another signal would add nothing — and a Notify that could
// block would put the write path back behind the relay, undoing the
// decoupling this design is for.
func (r *Relay[E]) Notify() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// Run tails the log until ctx is done or leadership is lost.
func (r *Relay[E]) Run(ctx context.Context) error {
	if !r.running.CompareAndSwap(false, true) {
		return ErrRunning
	}
	defer r.running.Store(false)

	release, lost, err := r.leader.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("relay %s: acquiring leadership: %w", r.opts.Name, err)
	}
	defer release()

	timer := time.NewTimer(r.opts.Idle)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-lost:
			return ErrLeadershipLost
		default:
		}

		drained, err := r.drainOnce(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if drained {
			continue // more may be waiting; do not sleep between full batches
		}

		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(r.opts.Idle)
		select {
		case <-ctx.Done():
			return nil
		case <-lost:
			return ErrLeadershipLost
		case <-r.wake:
		case <-timer.C:
		}
	}
}

// RunToEnd drains everything currently committed and returns. Tests and
// one-shot tools use it; Run is the production entry point.
func (r *Relay[E]) RunToEnd(ctx context.Context) error {
	if !r.running.CompareAndSwap(false, true) {
		return ErrRunning
	}
	defer r.running.Store(false)
	for {
		drained, err := r.drainOnce(ctx)
		if err != nil {
			return err
		}
		if !drained {
			return nil
		}
	}
}

// drainOnce reads one batch, publishes it, and advances the checkpoint.
// It reports whether the batch was full, meaning more may be waiting.
func (r *Relay[E]) drainOnce(ctx context.Context) (bool, error) {
	pos, err := r.cps.Get(ctx, r.opts.Name)
	if err != nil {
		return false, fmt.Errorf("relay %s: reading checkpoint: %w", r.opts.Name, err)
	}
	batch, err := r.reader.ReadAfter(ctx, pos, r.opts.Batch)
	if err != nil {
		return false, fmt.Errorf("relay %s: reading log: %w", r.opts.Name, err)
	}
	if len(batch) == 0 {
		return false, nil
	}
	r.batches.Add(1)

	for _, ev := range batch {
		pubs, err := r.mapper(ev)
		if err != nil {
			// A mapper that cannot render an event is a contract bug, not a
			// transient fault. Stopping here holds the checkpoint so the
			// event is neither published wrong nor silently skipped; the
			// relay retries and the error is visible.
			return false, fmt.Errorf("relay %s: mapping event at position %d: %w", r.opts.Name, ev.Position(), err)
		}
		if len(pubs) == 0 {
			r.skipped.Add(1)
		}
		for _, p := range pubs {
			if p.Msg.ID == "" {
				return false, fmt.Errorf("relay %s: event at position %d mapped to a message with no ID: "+
					"consumers would have no way to deduplicate a redelivery", r.opts.Name, ev.Position())
			}
			if err := r.pub.Publish(ctx, p.Topic, p.Msg); err != nil {
				// Checkpoint NOT advanced. This position republishes on the
				// next attempt, which is the at-least-once half of the
				// contract and why Msg.ID must be stable.
				return false, fmt.Errorf("relay %s: publishing position %d: %w", r.opts.Name, ev.Position(), err)
			}
			r.published.Add(1)
		}
		// Advance one position at a time. Checkpointing the whole batch only
		// at the end would republish the entire batch after a mid-batch
		// failure; per-event is a cheap write against a bounded republish.
		if err := r.cps.Set(ctx, r.opts.Name, ev.Position()); err != nil {
			return false, fmt.Errorf("relay %s: advancing checkpoint to %d: %w", r.opts.Name, ev.Position(), err)
		}
	}
	return len(batch) >= r.opts.Batch, nil
}

// Published returns how many messages this relay has published.
func (r *Relay[E]) Published() int64 { return r.published.Load() }

// Skipped returns how many events mapped to no publication at all.
func (r *Relay[E]) Skipped() int64 { return r.skipped.Load() }

// Batches returns how many non-empty batches have been drained.
func (r *Relay[E]) Batches() int64 { return r.batches.Load() }

// Lag returns how far the relay is behind the log head. It is the operational
// signal for "effects are not reaching the outside world" — the condition a
// separate outbox's pending-count used to report, now measured against the one
// store that exists.
func (r *Relay[E]) Lag(ctx context.Context) (int64, error) {
	head, err := r.reader.Head(ctx)
	if err != nil {
		return 0, err
	}
	pos, err := r.cps.Get(ctx, r.opts.Name)
	if err != nil {
		return 0, err
	}
	if head < pos {
		return 0, nil
	}
	return head - pos, nil
}
