package store

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	"github.com/<OWNER>/<SERVICE>/internal/platform/relay"
)

// LogPublisher is this template's real, working, dependency-free
// relay.Publisher: it "delivers" by emitting a structured log line.
//
// It is a legitimate end-to-end demonstration, not a stub — the relay's
// no-loss guarantee depends on a publisher confirming synchronously, and this
// one does, because the write returns before it does. Swap it for an
// HTTP/queue/broker publisher without touching the relay or the ledger.
//
// A REAL publisher must also confirm synchronously. Watermill's NATS, Kafka
// and AMQP publishers do; an async fire-and-forget one does not, and wiring
// one here would let the relay checkpoint past messages the broker never
// received — turning a crash into silent permanent loss.
type LogPublisher struct {
	logger *slog.Logger

	mu sync.Mutex
	// FailUntil, when > 0, makes Publish fail for every message ID it has
	// not yet delivered until it has been attempted FailUntil times for
	// that ID. A deterministic, injectable fault so tests can drive real
	// retry behaviour without a network.
	FailUntil int
	attempts  map[string]int
	delivered []relay.Message
}

// NewLogPublisher returns a LogPublisher writing through logger
// (slog.Default() when nil).
func NewLogPublisher(logger *slog.Logger) *LogPublisher {
	if logger == nil {
		logger = slog.Default()
	}
	return &LogPublisher{logger: logger, attempts: map[string]int{}}
}

// Publish implements relay.Publisher. It returns only after the "delivery"
// is complete, which is the contract the relay's ordering depends on.
//
// The ctx is USED, not discarded: the delivery line is emitted with
// InfoContext so it carries a trace context. This parameter was `_` until the
// correlation gap was measured -- a publisher whose delivery lines cannot be
// joined to the span that caused them is the single hardest thing to debug
// about a relay.
func (p *LogPublisher) Publish(ctx context.Context, topic string, msg relay.Message) error {
	// The CONSUMER's half of propagation, performed here because this
	// publisher is also the thing that observes the delivery. A real broker
	// client would hand msg.Metadata to the broker as headers and the
	// consumer process would call ExtractMetadata; this one delivers by
	// logging, so it extracts and logs under the restored context. Either
	// way the effect is the same and it is the point of the whole file: the
	// delivery line carries the trace_id of the COMMAND that committed the
	// event, across the durable gap -- a different goroutine, and possibly a
	// different process after a restart -- instead of no trace id at all.
	ctx = observability.ExtractMetadata(ctx, msg.Metadata)

	p.mu.Lock()
	defer p.mu.Unlock()
	p.attempts[msg.ID]++
	if p.FailUntil > 0 && p.attempts[msg.ID] < p.FailUntil {
		return fmt.Errorf("logpublisher: simulated failure (attempt %d/%d for %s)", p.attempts[msg.ID], p.FailUntil, msg.ID)
	}
	p.delivered = append(p.delivered, msg)
	p.logger.InfoContext(ctx, "relay delivery", "topic", topic, "message_id", msg.ID,
		"metadata", msg.Metadata, "bytes", len(msg.Payload))
	return nil
}

// Delivered returns the messages published so far, in order.
func (p *LogPublisher) Delivered() []relay.Message {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]relay.Message, len(p.delivered))
	copy(out, p.delivered)
	return out
}

// AttemptsFor reports how many times a message ID has been attempted — used
// by tests to assert that a retry reuses the SAME id rather than minting a
// new one.
func (p *LogPublisher) AttemptsFor(id string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.attempts[id]
}

// Envelope metadata keys. The es_ prefix is reserved for the envelope;
// mapper-provided event metadata must not use it.
//
// The envelope travels in METADATA rather than in the payload because most
// brokers map metadata to headers, where middlewares, dashboards and CLI
// tooling can read it WITHOUT unmarshaling a payload whose schema they may
// not have. The payload then carries exactly one thing: the integration
// contract bytes.
const (
	MetaEventID    = "es_event_id"
	MetaEventType  = "es_event_type"
	MetaPosition   = "es_position"
	MetaOrigin     = "es_origin"
	MetaForeignSeq = "es_foreign_seq"
	MetaSchema     = "es_schema"
)

// IntegrationSchema versions the PUBLISHED contract.
//
// It is separate from the event log's schema_version on purpose. The log's
// version governs a format only this service reads, so it can be migrated at
// will. This one governs a format other people's consumers parse, which
// cannot be migrated by deploying this repo — so the two evolve on different
// clocks and conflating them would let an internal refactor silently change a
// public contract.
const IntegrationSchema = "1"

// notification is the PUBLISHED shape: the integration contract.
//
// It is deliberately not domain.Effect. A domain type is free to be
// refactored; a published one is an API. Keeping a separate struct here means
// renaming a domain field is a local change, and changing this struct is
// visibly a contract change.
type notification struct {
	Type    string `json:"type"`
	EventID string `json:"event_id"`
	Amount  string `json:"amount"`
}

// EnvelopeMapper is the default relay.Mapper: it turns a stored event into
// the integration events a consumer outside this service receives.
//
// This function IS the domain -> integration boundary. Events that are
// internal-only map to nothing (no publications), which is how a fact stays
// inside the service.
//
// # Why this translates the event and does NOT re-derive effects
//
// The obvious implementation calls domain.Apply(domain.NewState(), event) and
// publishes the effects. It is wrong, and wrong SILENTLY. Admission depends on
// accumulated state, which is not in the event: replaying an admitted
// withdrawal of 5 against a fresh zero state yields EffectWithdrawalRejected,
// so the mapper drops it and the withdrawal is never published at all. This
// template shipped that bug; it was found by mapping one admitted withdrawal
// and counting the publications (0), and the regression test below is that
// case.
//
// The correct rule is structural: the relay maps events, and an event in the
// log is by construction a fact the domain already ADMITTED (internal/app's
// Ledger appends only on admission). So the mapper needs no state and no
// re-decision -- it is a pure per-event translation, 1:1, and cannot disagree
// with the write path about what happened.
//
// NOTE for services whose OUTGOING facts depend on accumulated state rather
// than on one event (a match against a book, a running total): do not reach
// for a re-fold here either. RAISE those derived facts as events of their own
// on the write path, where the state exists, and let this mapper stay a
// translation.
func EnvelopeMapper(topic string) relay.Mapper[eventlog.SeqEvent] {
	return func(se eventlog.SeqEvent) ([]relay.Publication, error) {
		var n notification
		switch se.Event.Type {
		case domain.EventDeposited:
			n = notification{Type: "units.deposited", EventID: se.Event.ID, Amount: se.Event.Amount}
		case domain.EventWithdrawn:
			n = notification{Type: "units.withdrawn", EventID: se.Event.ID, Amount: se.Event.Amount}
		default:
			// Internal-only, or a type this build does not know. Publishing
			// nothing is right for the first and the only safe option for
			// the second: inventing an integration event for an unknown
			// type would put a shape on the wire no consumer has a contract
			// for. The relay still advances past it, so one unrecognized
			// event cannot stall delivery of everything behind it.
			return nil, nil
		}
		payload, err := json.Marshal(n)
		if err != nil {
			return nil, fmt.Errorf("store: encoding notification for event %s: %w", se.Event.ID, err)
		}
		metadata := map[string]string{
			MetaEventID:    se.Event.ID,
			MetaEventType:  string(se.Event.Type),
			MetaPosition:   fmt.Sprintf("%d", se.Seq),
			MetaOrigin:     string(se.Origin),
			MetaForeignSeq: fmt.Sprintf("%d", se.ForeignSeq),
			MetaSchema:     IntegrationSchema,
		}
		// THE EGRESS HALF OF TRACE PROPAGATION, and the reason the event log
		// persists a traceparent at all.
		//
		// Two steps, both necessary. ContextWithTraceParent rebuilds the
		// committing span as a REMOTE parent (it has already ended, perhaps in
		// a previous process); InjectMetadata then writes it back out through
		// the propagator, so what leaves this service is whatever the W3C
		// propagator says the header should be, not a string this file copied
		// by hand. A record with no traceparent -- committed outside a span,
		// or written by a build that predates the field -- injects nothing and
		// publishes exactly as before.
		//
		// Written with the propagator's own key ("traceparent", lowercase and
		// verbatim), NOT canonicalized: see propagation.go for the header a
		// message consumer never finds.
		observability.InjectMetadata(
			observability.ContextWithTraceParent(context.Background(), se.TraceParent),
			metadata,
		)
		return []relay.Publication{{
			Topic: topic,
			Msg: relay.Message{
				// The message id IS the persisted event id. Stable across
				// redeliveries, so a consumer deduplicates on it; a fresh id
				// per attempt would present a resumed delivery as a brand-new
				// fact.
				ID:       se.Event.ID,
				Payload:  payload,
				Metadata: metadata,
			},
		}}, nil
	}
}
