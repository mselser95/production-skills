package store

import (
	"context"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// provenance: regression
// verifies: the EGRESS half -- the envelope a consumer receives carries the
// traceparent of the command that committed the fact, in the exact key a
// consumer looks up, without disturbing the envelope that was already there.
//
// This is the boundary the standard's `observability:trace_propagation` row
// exists for. Before it, this service published every integration event with
// six envelope headers and no trace context at all: the consumer's span was a
// new root, so the fact and its announcement lived in two different traces
// with nothing linking them.
func TestEnvelopeMapper_InjectsTheCommittingTraceIntoTheMessageMetadata(t *testing.T) {
	ctx, span := observability.NewLog(nil).StartSpan(context.Background(), "svc.deposit", nil)
	span.End()
	committing := oteltrace.SpanContextFromContext(ctx)
	if !committing.IsValid() {
		t.Fatal("no span context to propagate -- the assertions below would be vacuous")
	}

	pubs, err := EnvelopeMapper("units")(eventlog.SeqEvent{
		Seq:         7,
		Origin:      eventlog.OriginRaised,
		TraceParent: observability.TraceParentFromContext(ctx),
		Event:       domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
	})
	if err != nil {
		t.Fatalf("EnvelopeMapper: %v", err)
	}
	if len(pubs) != 1 {
		t.Fatalf("mapped to %d publications, want 1", len(pubs))
	}
	metadata := pubs[0].Msg.Metadata

	if _, ok := metadata[observability.TraceParentHeader]; !ok {
		t.Fatalf("published metadata %v carries no %q -- the consumer's span is a new root and "+
			"nothing links the fact to its announcement", metadata, observability.TraceParentHeader)
	}

	// Round trip through the CONSUMER's call, not a string comparison: what
	// matters is that the far side can rebuild this trace.
	got := oteltrace.SpanContextFromContext(observability.ExtractMetadata(context.Background(), metadata))
	if got.TraceID() != committing.TraceID() || got.SpanID() != committing.SpanID() {
		t.Fatalf("a consumer extracting the envelope gets %s/%s, want the committing span %s/%s",
			got.TraceID(), got.SpanID(), committing.TraceID(), committing.SpanID())
	}

	// The envelope a consumer deduplicates on must be untouched.
	for key, want := range map[string]string{
		MetaEventID:    "e1",
		MetaEventType:  string(domain.EventDeposited),
		MetaPosition:   "7",
		MetaOrigin:     string(eventlog.OriginRaised),
		MetaForeignSeq: "0",
		MetaSchema:     IntegrationSchema,
	} {
		if metadata[key] != want {
			t.Errorf("injection disturbed envelope key %q: got %q, want %q", key, metadata[key], want)
		}
	}
}

// provenance: derived
// verifies: an event committed outside any span -- or written by a build that
// predates the traceparent field -- publishes exactly as before.
//
// A record with no provenance must still be DELIVERED. Refusing, or inventing
// a parent for it, would trade a real delivery for a telemetry nicety.
func TestEnvelopeMapper_WithoutAStoredTraceParentPublishesTheSameEnvelope(t *testing.T) {
	pubs, err := EnvelopeMapper("units")(eventlog.SeqEvent{
		Seq:   7,
		Event: domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"},
	})
	if err != nil {
		t.Fatalf("EnvelopeMapper: %v", err)
	}
	if len(pubs) != 1 {
		t.Fatalf("mapped to %d publications, want 1", len(pubs))
	}
	if _, ok := pubs[0].Msg.Metadata[observability.TraceParentHeader]; ok {
		t.Fatalf("invented a traceparent for a fact that has none: %v", pubs[0].Msg.Metadata)
	}
	if got := len(pubs[0].Msg.Metadata); got != 6 {
		t.Fatalf("metadata has %d keys, want the 6 envelope keys and nothing else: %v",
			got, pubs[0].Msg.Metadata)
	}
}
