// Package observability is the tracing PORT this service exposes to its
// adapters: a small, dependency-free contract for making a critical state
// transition observable as a span, without pulling any tracing library into
// go.mod.
//
// The default implementation (NewNoop) is a pure no-op: accepting this port
// changes nothing about production behavior until a real Tracer is wired in
// at the composition root via Config.Tracing / NewTracer.
package observability

import "context"

// Tracer starts spans for critical state transitions. Every adapter that
// accepts one defaults to NewNoop() when none is configured.
type Tracer interface {
	// StartSpan begins a span named `name` carrying `attrs` and returns the
	// (possibly derived) context plus the Span the caller must End exactly
	// once, typically via defer.
	StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span)
}

// Span is the handle returned by StartSpan.
type Span interface {
	// End closes the span.
	End()
	// RecordError marks the span as failed and attaches err. A nil err is a
	// no-op.
	RecordError(err error)
}

// NewNoop returns the default Tracer: StartSpan and every Span method are
// cheap no-ops.
func NewNoop() Tracer { return noopTracer{} }

type noopTracer struct{}

func (noopTracer) StartSpan(ctx context.Context, _ string, _ map[string]string) (context.Context, Span) {
	return ctx, noopSpan{}
}

type noopSpan struct{}

func (noopSpan) End()              {}
func (noopSpan) RecordError(error) {}
