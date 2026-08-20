package eventlog

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// provenance: regression
// verifies: the log CARRIES the committing span across the durable gap --
// Append persists the caller's traceparent and ReadAfter hands it back, so the
// relay can publish a fact inside the trace that committed it.
//
// THE LOG IS THE OUTBOX, and that is exactly what makes this necessary rather
// than nice: the command commits under a span and returns, and the relay
// publishes later, from another goroutine and possibly another process after a
// restart. A context does not survive that. Without this field every published
// event is a fresh root, which is the shape that produced 3132 traces for 3132
// spans in the service this template was extracted from.
//
// Asserted through a REOPENED log, not through the in-memory writer, because
// the whole claim is about surviving a process boundary.
func TestAppend_PersistsTheCommittingTraceParentAcrossAReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")

	log, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	ctx, span := observability.NewLog(nil).StartSpan(context.Background(), "svc.deposit", nil)
	committing := oteltrace.SpanContextFromContext(ctx)
	if !committing.IsValid() {
		t.Fatal("no span context to persist -- the assertion below would be vacuous")
	}
	if err := log.Append(ctx, domain.Event{ID: "e1", Type: domain.EventDeposited, Amount: "10"}); err != nil {
		t.Fatalf("Append under a span: %v", err)
	}
	// A fact committed outside any span: the pre-propagation shape, and the
	// shape of every fact a background job commits.
	if err := log.Append(context.Background(), domain.Event{ID: "e2", Type: domain.EventDeposited, Amount: "1"}); err != nil {
		t.Fatalf("Append without a span: %v", err)
	}
	span.End()
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// -- a different process --------------------------------------------
	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()

	events, err := reopened.ReadAfter(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ReadAfter: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("read %d events, want 2", len(events))
	}
	if events[0].TraceParent == "" {
		t.Fatal("the committing traceparent was NOT persisted -- the publish of this fact " +
			"will be an orphan root, unjoinable to the command that decided it")
	}
	restored := oteltrace.SpanContextFromContext(
		observability.ContextWithTraceParent(context.Background(), events[0].TraceParent))
	if restored.TraceID() != committing.TraceID() || restored.SpanID() != committing.SpanID() {
		t.Fatalf("restored %s/%s from the log, want the committing span %s/%s",
			restored.TraceID(), restored.SpanID(), committing.TraceID(), committing.SpanID())
	}
	if events[1].TraceParent != "" {
		t.Fatalf("a fact committed outside any span recorded traceparent %q -- an invented "+
			"parent is worse than none", events[1].TraceParent)
	}
}
